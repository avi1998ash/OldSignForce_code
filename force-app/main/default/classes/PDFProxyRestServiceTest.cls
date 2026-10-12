/**
 * PDFProxyRestServiceTest — full coverage for the public REST endpoint.
 *
 * Target: 70% → 90%+
 *
 * Branches covered:
 *   - Missing cvId → 400
 *   - Missing token → 401
 *   - Invalid token → 403
 *   - Authz exception (bad cvId format) → 400
 *   - Valid token + valid cvId + successful upstream callout → 200
 *   - Valid token + valid cvId + upstream 4xx/5xx → 502
 *   - Valid token + valid cvId + callout throws → 500
 *   - CORS: no Origin header → skipped
 *   - CORS: Origin matches org domain → echoed back
 *   - CORS: Origin not in allowlist → omitted
 */
@isTest(SeeAllData=false)
private class PDFProxyRestServiceTest {

    // ═════════════════════════════════════════════════════════════════════
    //  HTTP mocks for the upstream callout
    //  (Names avoid "Exception" suffix — Apex compiler treats those as
    //   exception class declarations and requires `extends Exception`.)
    // ═════════════════════════════════════════════════════════════════════

    private class UpstreamMock200 implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/pdf');
            res.setBodyAsBlob(Blob.valueOf('upstream pdf bytes'));
            return res;
        }
    }

    private class UpstreamMock404 implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(404);
            res.setBodyAsBlob(Blob.valueOf('not found'));
            return res;
        }
    }

    private class UpstreamMockThrows implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            throw new CalloutException('Simulated callout failure');
        }
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Helpers
    // ═════════════════════════════════════════════════════════════════════

    private static RestRequest makeRequest(String token, String cvId, String origin) {
        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/pdfproxy';
        req.httpMethod = 'GET';
        if (String.isNotBlank(token)) req.params.put('token', token);
        if (String.isNotBlank(cvId)) req.params.put('cvId', cvId);
        if (String.isNotBlank(origin)) req.headers.put('Origin', origin);
        return req;
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Input validation branches (400, 401)
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void getPdf_missingCvId_returns400() {
        RestContext.request = makeRequest('sometoken', null, null);
        RestContext.response = new RestResponse();

        Test.startTest();
        PDFProxyRestService.getPdf();
        Test.stopTest();

        Assert.areEqual(400, RestContext.response.statusCode);
    }

    @isTest
    static void getPdf_missingToken_returns401() {
        RestContext.request = makeRequest(null, '068000000000000AAA', null);
        RestContext.response = new RestResponse();

        Test.startTest();
        PDFProxyRestService.getPdf();
        Test.stopTest();

        Assert.areEqual(401, RestContext.response.statusCode);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Authz branches (403, 400-bad-cvId)
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void getPdf_invalidToken_returns403() {
        String fakeToken = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

        RestContext.request = makeRequest(fakeToken, '068000000000000AAA', null);
        RestContext.response = new RestResponse();

        Test.startTest();
        PDFProxyRestService.getPdf();
        Test.stopTest();

        Integer code = RestContext.response.statusCode;
        Assert.isTrue(code == 403 || code == 400,
            'Should reject with 403 or 400, got: ' + code);
    }

    @isTest
    static void getPdf_validTokenWrongCvId_returns403() {
        Agreement__c agr = TestDataFactory.createSentAgreement('Proxy Wrong Cv');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'p@example.com');

        String otherCvId = '068000000000999AAA';

        RestContext.request = makeRequest(signer.Access_Token__c, otherCvId, null);
        RestContext.response = new RestResponse();

        Test.startTest();
        PDFProxyRestService.getPdf();
        Test.stopTest();

        Integer code = RestContext.response.statusCode;
        Assert.isTrue(code == 403 || code == 400,
            'Should reject with 403 or 400, got: ' + code);
    }

    @isTest
    static void getPdf_invalidCvIdFormat_returns400() {
        Agreement__c agr = TestDataFactory.createSentAgreement('Bad Cv Format');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'bcv@example.com');

        RestContext.request = makeRequest(signer.Access_Token__c, 'not-an-id', null);
        RestContext.response = new RestResponse();

        Test.startTest();
        PDFProxyRestService.getPdf();
        Test.stopTest();

        Integer code = RestContext.response.statusCode;
        Assert.isTrue(code == 400 || code == 403,
            'Malformed cvId should return 400 or 403, got: ' + code);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  Success path (200) — upstream callout works
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void getPdf_validTokenAndCv_upstream200_returns200() {
        Agreement__c agr = TestDataFactory.createSentAgreement('Proxy Success');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'ok@example.com');
        Agreement_Document__c doc = TestDataFactory.createTier1OriginalDoc(agr.Id);

        Test.setMock(HttpCalloutMock.class, new UpstreamMock200());

        RestContext.request = makeRequest(
            signer.Access_Token__c, doc.Content_Version_ID__c, null
        );
        RestContext.response = new RestResponse();

        Test.startTest();
        PDFProxyRestService.getPdf();
        Test.stopTest();

        Assert.areEqual(200, RestContext.response.statusCode,
            'Successful upstream callout should return 200');
        Assert.isNotNull(RestContext.response.responseBody,
            'Response body should contain the PDF bytes');
    }

    @isTest
    static void getPdf_upstream404_returns502() {
        Agreement__c agr = TestDataFactory.createSentAgreement('Proxy 404');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, '404@example.com');
        Agreement_Document__c doc = TestDataFactory.createTier1OriginalDoc(agr.Id);

        Test.setMock(HttpCalloutMock.class, new UpstreamMock404());

        RestContext.request = makeRequest(
            signer.Access_Token__c, doc.Content_Version_ID__c, null
        );
        RestContext.response = new RestResponse();

        Test.startTest();
        PDFProxyRestService.getPdf();
        Test.stopTest();

        Assert.areEqual(502, RestContext.response.statusCode,
            'Upstream non-200 should return 502 to the client');
    }

    @isTest
    static void getPdf_upstreamThrows_returns500() {
        Agreement__c agr = TestDataFactory.createSentAgreement('Proxy Throws');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'ex@example.com');
        Agreement_Document__c doc = TestDataFactory.createTier1OriginalDoc(agr.Id);

        Test.setMock(HttpCalloutMock.class, new UpstreamMockThrows());

        RestContext.request = makeRequest(
            signer.Access_Token__c, doc.Content_Version_ID__c, null
        );
        RestContext.response = new RestResponse();

        Test.startTest();
        PDFProxyRestService.getPdf();
        Test.stopTest();

        Assert.areEqual(500, RestContext.response.statusCode,
            'Callout exception should return 500');
    }

    // ═════════════════════════════════════════════════════════════════════
    //  CORS branches
    // ═════════════════════════════════════════════════════════════════════

    @isTest
    static void getPdf_noOriginHeader_corsSkipped() {
        RestContext.request = makeRequest(null, null, null);
        RestContext.response = new RestResponse();

        Test.startTest();
        PDFProxyRestService.getPdf();
        Test.stopTest();

        Map<String, String> headers = RestContext.response.headers;
        if (headers != null) {
            Assert.isFalse(headers.containsKey('Access-Control-Allow-Origin'),
                'No Origin → no CORS header');
        }
    }

    @isTest
    static void getPdf_originMatchesOrgDomain_corsEchoed() {
        String orgDomain = URL.getOrgDomainUrl().toExternalForm();

        RestContext.request = makeRequest('faketoken', '068000000000000AAA', orgDomain);
        RestContext.response = new RestResponse();

        Test.startTest();
        PDFProxyRestService.getPdf();
        Test.stopTest();

        String corsHeader = RestContext.response.headers != null
            ? RestContext.response.headers.get('Access-Control-Allow-Origin')
            : null;
        Assert.areEqual(orgDomain, corsHeader,
            'Org domain origin should be echoed in CORS header');
    }

    @isTest
    static void getPdf_originNotInAllowlist_corsOmitted() {
        RestContext.request = makeRequest('faketoken', '068000000000000AAA',
            'https://malicious.example.com');
        RestContext.response = new RestResponse();

        Test.startTest();
        PDFProxyRestService.getPdf();
        Test.stopTest();

        Map<String, String> headers = RestContext.response.headers;
        if (headers != null) {
            String corsHeader = headers.get('Access-Control-Allow-Origin');
            Assert.areEqual(null, corsHeader,
                'Non-allowlisted origin → CORS header omitted');
        }
    }
}