@isTest
private class IntegrationAdminTest {

    private class Mock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse r = new HttpResponse();
            r.setStatusCode(200);
            r.setBody('{"success":true,"message":"Connected","url":"https://accounts.google.com/o/oauth2/v2/auth?x=1"}');
            return r;
        }
    }

    private static void useEndpoint() {
        SignForceConfigService.lambdaEndpointOverride = 'https://lambda.test/signforce';
    }

    @isTest
    static void integrationConfig_roundtrip() {
        List<SignForceAdminConfigController.IntegrationConfig> before =
            SignForceAdminConfigController.getIntegrationConfig();
        System.assertEquals(5, before.size(), 'Expect one row per provider (AwsS3, Box, GoogleDrive, OneDrive, SharePoint)');

        List<SignForceAdminConfigController.IntegrationConfig> upd =
            new List<SignForceAdminConfigController.IntegrationConfig>{
                new SignForceAdminConfigController.IntegrationConfig('AwsS3', true, 'my-bucket/signed'),
                new SignForceAdminConfigController.IntegrationConfig('Box', false, null),
                new SignForceAdminConfigController.IntegrationConfig('GoogleDrive', true, 'folderXYZ'),
                new SignForceAdminConfigController.IntegrationConfig('SharePoint', false, '')
            };
        Test.startTest();
        SignForceAdminConfigController.saveIntegrationConfig(JSON.serialize(upd));
        Test.stopTest();

        SignForce_Admin_Config__c cs = SignForce_Admin_Config__c.getOrgDefaults();
        System.assertEquals(true, cs.Integration_AwsS3_Enabled__c);
        System.assertEquals('my-bucket/signed', cs.Integration_AwsS3_Target__c);
        System.assertEquals(true, cs.Integration_GoogleDrive_Enabled__c);
        System.assertEquals('folderXYZ', cs.Integration_GoogleDrive_Target__c);
        System.assertEquals(false, cs.Integration_Box_Enabled__c);
    }

    @isTest
    static void testIntegration_success() {
        SignForce_Admin_Config__c cs = SignForce_Admin_Config__c.getOrgDefaults();
        cs.Integration_AwsS3_Enabled__c = true;
        cs.Integration_AwsS3_Target__c = 'my-bucket/prefix';
        upsert cs;

        useEndpoint();
        Test.setMock(HttpCalloutMock.class, new Mock());
        Test.startTest();
        SignForceAdminConfigController.IntegrationActionResult r = SignForceAdminConfigController.testIntegration('AwsS3');
        Test.stopTest();
        System.assert(r.success, 'testIntegration should succeed: ' + r.message);
    }

    @isTest
    static void getConnectUrl_returnsUrl() {
        SignForce_Admin_Config__c cs = SignForce_Admin_Config__c.getOrgDefaults();
        cs.Integration_GoogleDrive_Enabled__c = true;
        cs.Integration_GoogleDrive_Target__c = 'folderXYZ';
        upsert cs;

        useEndpoint();
        Test.setMock(HttpCalloutMock.class, new Mock());
        Test.startTest();
        SignForceAdminConfigController.IntegrationActionResult r =
            SignForceAdminConfigController.getIntegrationConnectUrl('GoogleDrive');
        Test.stopTest();
        System.assert(r.success, r.message);
        System.assert(r.url != null && r.url.startsWith('https://'), 'url: ' + r.url);
    }
}