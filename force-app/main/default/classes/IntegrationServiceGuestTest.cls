/**
 * IntegrationServiceGuestTest - coverage for IntegrationServiceGuest, the guest-side copy of the
 * IntegrationService completion-push chain. Same cases as IntegrationServiceTest / AgreementControllerCloudTest
 * for the methods the guest copy holds, repointed at IntegrationServiceGuest. Guest config reads go through
 * SignForceConfigServiceGuest, so tests set ITS lambdaEndpointOverride.
 */
@isTest
private class IntegrationServiceGuestTest {

    @TestSetup
    static void setup() {
        insert new SignForce_Admin_Config__c(
            SetupOwnerId = UserInfo.getOrganizationId(),
            Integration_AwsS3_Enabled__c = true,
            Integration_AwsS3_Target__c = 'my-bucket/signed',
            Integration_Box_Enabled__c = false
        );
        insert new Agreement__c(
            Name = 'Integ Guest Test Agreement', Status__c = 'Completed',
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

    private class CloudLambdaMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            res.setBody(JSON.serialize(new Map<String, Object>{
                'success'          => true,
                'fileId'           => 'drive-file-1',
                'externalId'       => 'drive-file-1',
                'mainFolderId'     => 'main-1',
                'originalFolderId' => 'orig-1',
                'stampedFolderId'  => 'stamp-1',
                'certFolderId'     => 'cert-1',
                'url'              => 'https://example.com/x',
                'status'           => 'OK'
            }));
            return res;
        }
    }

    private static Blob doc() { return Blob.valueOf('%PDF-1.4 fake'); }
    private static void useEndpoint() {
        SignForceConfigServiceGuest.lambdaEndpointOverride = 'https://lambda.test/signforce';
    }
    private static void enableGoogleDrive() {
        SignForce_Admin_Config__c cfg = SignForce_Admin_Config__c.getOrgDefaults();
        cfg.Integration_GoogleDrive_Enabled__c = true;
        cfg.Integration_GoogleDrive_Target__c  = 'root-1';
        upsert cfg;
    }

    @isTest
    static void pushDocument_eachProvider_success() {
        useEndpoint();
        Test.setMock(HttpCalloutMock.class, new FixedMock(200, '{"success":true,"externalId":"abc123"}'));
        Test.startTest();
        for (String p : IntegrationServiceGuest.PROVIDERS) {
            IntegrationServiceGuest.Result r =
                IntegrationServiceGuest.pushDocument(p, 'doc.pdf', doc(), 'application/pdf', 'folder1');
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
        IntegrationServiceGuest.Result r =
            IntegrationServiceGuest.pushDocument(IntegrationServiceGuest.BOX, 'd.pdf', doc(), null, null);
        Test.stopTest();
        System.assert(!r.success);
        System.assertEquals('no folder', r.message);
    }

    @isTest
    static void pushDocument_unknownProvider() {
        IntegrationServiceGuest.Result r =
            IntegrationServiceGuest.pushDocument('Dropbox', 'd.pdf', doc(), null, null);
        System.assert(!r.success);
        System.assert(r.message.containsIgnoreCase('Unknown provider'));
    }

    @isTest
    static void pushDocument_httpError_isReported() {
        useEndpoint();
        Test.setMock(HttpCalloutMock.class, new FixedMock(500, '{"message":"server down"}'));
        Test.startTest();
        IntegrationServiceGuest.Result r =
            IntegrationServiceGuest.pushDocument(IntegrationServiceGuest.AWS_S3, 'd.pdf', doc(), null, null);
        Test.stopTest();
        System.assert(!r.success);
        System.assertEquals('server down', r.message);
    }

    @isTest
    static void anyEnabled_reflectsConfig() {
        System.assert(IntegrationServiceGuest.anyEnabled(), 'AwsS3 enabled in setup');
    }

    @isTest
    static void primaryProvider_nullWhenOnlyS3Enabled_andFindsDriveWhenConfigured() {
        System.assertEquals(null, IntegrationServiceGuest.primaryProvider());
        enableGoogleDrive();
        System.assertEquals(IntegrationServiceGuest.GOOGLE_DRIVE, IntegrationServiceGuest.primaryProvider());
    }

    @isTest
    static void credsFor_returnsClientIdAndSecret() {
        Map<String, Object> g = IntegrationServiceGuest.credsFor(IntegrationServiceGuest.GOOGLE_DRIVE);
        Map<String, Object> m = IntegrationServiceGuest.credsFor(IntegrationServiceGuest.ONE_DRIVE);
        System.assert(g.containsKey('clientId') && g.containsKey('clientSecret'));
        System.assert(m.containsKey('clientId') && m.containsKey('clientSecret'));
    }

    @isTest
    static void pushAgreementDocuments_bestEffort() {
        useEndpoint();
        Test.setMock(HttpCalloutMock.class, new FixedMock(200, '{"success":true}'));
        Agreement__c agr = [SELECT Id FROM Agreement__c WITH USER_MODE LIMIT 1];
        Test.startTest();
        IntegrationServiceGuest.pushAgreementDocuments(agr.Id);
        IntegrationServiceGuest.pushAgreementDocuments(null);
        Test.stopTest();
        System.assert(true, 'pushAgreementDocuments must never throw');
    }

    @isTest
    static void helpers_isEnabled_targetFor() {
        SignForce_Admin_Config__c cfg = new SignForce_Admin_Config__c(
            Integration_GoogleDrive_Enabled__c = true,
            Integration_GoogleDrive_Target__c = 'gd-folder'
        );
        System.assert(IntegrationServiceGuest.isEnabled(cfg, IntegrationServiceGuest.GOOGLE_DRIVE));
        System.assertEquals('gd-folder', IntegrationServiceGuest.targetFor(cfg, IntegrationServiceGuest.GOOGLE_DRIVE));
        System.assert(!IntegrationServiceGuest.isEnabled(cfg, IntegrationServiceGuest.BOX));
        System.assert(!IntegrationServiceGuest.isEnabled(null, IntegrationServiceGuest.AWS_S3));
        System.assertEquals(null, IntegrationServiceGuest.targetFor(null, IntegrationServiceGuest.AWS_S3));
    }

    @isTest
    static void cloudFolderName_sanitizesAndFallsBack() {
        Agreement__c agr = [SELECT Id FROM Agreement__c WITH USER_MODE LIMIT 1];
        String cleaned = IntegrationServiceGuest.cloudFolderName('Bad/Name:With*Chars?', agr.Id);
        System.assert(!(cleaned.contains('/') || cleaned.contains(':') || cleaned.contains('*') || cleaned.contains('?')),
            'Invalid folder chars stripped: ' + cleaned);
        String fallback = IntegrationServiceGuest.cloudFolderName('   ', agr.Id);
        System.assert(fallback.startsWith('Agreement_'), 'Blank name falls back to id');
    }

    @isTest
    static void pushAgreementDocuments_reusesExistingFolderTree() {
        enableGoogleDrive();
        Agreement__c agr = TestDataFactory.createSentAgreement('Push Reuse Guest');
        agr.Cloud_Provider__c           = 'GoogleDrive';
        agr.Cloud_Main_Folder_Id__c     = 'main-keep';
        agr.Cloud_Original_Folder_Id__c = 'orig-keep';
        agr.Cloud_Stamped_Folder_Id__c  = 'stamp-keep';
        agr.Cloud_Cert_Folder_Id__c     = 'cert-keep';
        update agr;
        TestDataFactory.createTier1OriginalDoc(agr.Id);
        Test.setMock(HttpCalloutMock.class, new CloudLambdaMock());
        Test.startTest();
        IntegrationServiceGuest.pushAgreementDocuments(agr.Id);
        Test.stopTest();
        Agreement__c after = [SELECT Cloud_Main_Folder_Id__c FROM Agreement__c WHERE Id = :agr.Id WITH USER_MODE];
        System.assertEquals('main-keep', after.Cloud_Main_Folder_Id__c, 'Existing folder ids must be reused, never replaced');
        System.assert([SELECT COUNT() FROM Task WHERE WhatId = :agr.Id AND Subject LIKE 'Cloud Upload:%' WITH USER_MODE] > 0,
            'Status Task should be logged');
    }

    @isTest
    static void pushAgreementDocuments_firstTime_persistsFolderIds() {
        enableGoogleDrive();
        Agreement__c agr = TestDataFactory.createSentAgreement('Push First Guest');
        TestDataFactory.createTier1OriginalDoc(agr.Id);
        Test.setMock(HttpCalloutMock.class, new CloudLambdaMock());
        Test.startTest();
        IntegrationServiceGuest.pushAgreementDocuments(agr.Id);
        Test.stopTest();
        Agreement__c after = [SELECT Cloud_Main_Folder_Id__c FROM Agreement__c WHERE Id = :agr.Id WITH USER_MODE];
        System.assertEquals('main-1', after.Cloud_Main_Folder_Id__c, 'First-time folder tree ids must be persisted for reuse');
    }
}
