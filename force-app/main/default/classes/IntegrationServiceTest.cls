@isTest
private class IntegrationServiceTest {

    // Committed in @TestSetup so test methods can call out without
    // "uncommitted work pending" (DML-before-callout) errors.
    @TestSetup
    static void setup() {
        insert new SignForce_Admin_Config__c(
            SetupOwnerId = UserInfo.getOrganizationId(),
            Integration_AwsS3_Enabled__c = true,
            Integration_AwsS3_Target__c = 'my-bucket/signed',
            Integration_Box_Enabled__c = false
        );
        insert new Agreement__c(
            Name = 'Integ Test Agreement', Status__c = 'Completed',
            Agreement_Type__c = 'Standard', Signing_Order__c = 'Sequential'
        );
    }

    private class FixedMock implements HttpCalloutMock {
        Integer code; String body;
        FixedMock(Integer code, String body) { this.code = code; this.body = body; }
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(code);
            res.setHeader('Content-Type', 'application/json');
            if (body != null) res.setBody(body);
            return res;
        }
    }

    private static Blob doc() { return Blob.valueOf('%PDF-1.4 fake'); }
    private static void useEndpoint() {
        SignForceConfigService.lambdaEndpointOverride = 'https://lambda.test/signforce';
    }

    @isTest
    static void pushDocument_eachProvider_success() {
        useEndpoint();
        Test.setMock(HttpCalloutMock.class, new FixedMock(200, '{"success":true,"externalId":"abc123"}'));
        Test.startTest();
        for (String p : IntegrationService.PROVIDERS) {
            IntegrationService.Result r =
                IntegrationService.pushDocument(p, 'doc.pdf', doc(), 'application/pdf', 'folder1');
            System.assert(r.success, p + ' should succeed: ' + r.message);
            System.assertEquals('abc123', r.externalId);
        }
        Test.stopTest();
    }

    @isTest
    static void pushDocument_backendFailure() {
        useEndpoint();
        Test.setMock(HttpCalloutMock.class, new FixedMock(200, '{"success":false,"message":"no folder"}'));
        Test.startTest();
        IntegrationService.Result r =
            IntegrationService.pushDocument(IntegrationService.BOX, 'd.pdf', doc(), null, null);
        Test.stopTest();
        System.assert(!r.success);
        System.assertEquals('no folder', r.message);
    }

    @isTest
    static void pushDocument_unknownProvider() {
        IntegrationService.Result r =
            IntegrationService.pushDocument('Dropbox', 'd.pdf', doc(), null, null);
        System.assert(!r.success);
        System.assert(r.message.containsIgnoreCase('Unknown provider'));
    }

    @isTest
    static void testConnection_success() {
        useEndpoint();
        Test.setMock(HttpCalloutMock.class, new FixedMock(200, '{"success":true,"message":"Connected"}'));
        Test.startTest();
        IntegrationService.Result r = IntegrationService.testConnection(IntegrationService.GOOGLE_DRIVE);
        Test.stopTest();
        System.assert(r.success, r.message);
        System.assert(!IntegrationService.testConnection('Nope').success);
    }

    @isTest
    static void getConnectUrl_returnsUrl_and_guards() {
        useEndpoint();
        Test.setMock(HttpCalloutMock.class, new FixedMock(200,
            '{"success":true,"url":"https://accounts.google.com/o/oauth2/v2/auth?x=1"}'));
        Test.startTest();
        IntegrationService.Result r = IntegrationService.getConnectUrl(IntegrationService.GOOGLE_DRIVE);
        Test.stopTest();
        System.assert(r.success, r.message);
        System.assert(r.url != null && r.url.startsWith('https://'), 'url: ' + r.url);
        System.assert(!IntegrationService.getConnectUrl(IntegrationService.AWS_S3).success, 'S3 has no login');
        System.assert(!IntegrationService.getConnectUrl('Nope').success);
    }

    @isTest
    static void pushToEnabled_respectsConfig() {
        useEndpoint();
        Test.setMock(HttpCalloutMock.class, new FixedMock(200, '{"success":true}'));
        Test.startTest();
        List<IntegrationService.Result> rs =
            IntegrationService.pushToEnabled('final.pdf', doc(), 'application/pdf');
        Test.stopTest();
        System.assertEquals(1, rs.size(), 'Only the one enabled provider should be pushed');
        System.assertEquals(IntegrationService.AWS_S3, rs[0].provider);
        System.assert(rs[0].success, rs[0].message);
    }

    @isTest
    static void anyEnabled_reflectsConfig() {
        System.assert(IntegrationService.anyEnabled(), 'AwsS3 enabled in setup');
    }

    @isTest
    static void pushAgreementDocuments_bestEffort() {
        useEndpoint();
        Test.setMock(HttpCalloutMock.class, new FixedMock(200, '{"success":true}'));
        Agreement__c agr = [SELECT Id FROM Agreement__c WITH USER_MODE LIMIT 1];
        Test.startTest();
        IntegrationService.pushAgreementDocuments(agr.Id); // enabled -> POST to backend (mocked)
        IntegrationService.pushAgreementDocuments(null);   // null-safe no-op
        Test.stopTest();
        System.assert(true, 'pushAgreementDocuments must never throw');
    }

    @isTest
    static void helpers_isEnabled_targetFor() {
        SignForce_Admin_Config__c cfg = new SignForce_Admin_Config__c(
            Integration_GoogleDrive_Enabled__c = true,
            Integration_GoogleDrive_Target__c = 'gd-folder'
        );
        System.assert(IntegrationService.isEnabled(cfg, IntegrationService.GOOGLE_DRIVE));
        System.assertEquals('gd-folder', IntegrationService.targetFor(cfg, IntegrationService.GOOGLE_DRIVE));
        System.assert(!IntegrationService.isEnabled(cfg, IntegrationService.BOX));
        System.assert(!IntegrationService.isEnabled(null, IntegrationService.AWS_S3));
    }
}