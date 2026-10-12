/**
 * SignForceAdminConfigExtraTest — covers the cloud-folder + disconnect endpoints
 * of SignForceAdminConfigController that the base test skips (the biggest
 * uncovered block): listGoogleFolders, listOneDriveFolders, createGoogleFolder,
 * createOneDriveFolder, disconnectIntegration, plus hasAdminAccess and the guest
 * assigned-id reader. Each callout path is exercised for success, provider-
 * failure (success:false), and HTTP-error branches.
 */
@isTest
private class SignForceAdminConfigExtraTest {

    // Returns a folder-list / create-folder / disconnect success body — the union
    // of fields every endpoint reads, so one mock serves all success paths.
    private class OkMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse r = new HttpResponse();
            r.setStatusCode(200);
            r.setBody('{"success":true,"message":"Disconnected",'
                + '"folderId":"nf-1","folderName":"New Folder",'
                + '"folders":[{"id":"f-1","name":"Alpha"},{"id":"f-2","name":"Beta"}]}');
            return r;
        }
    }

    // Backend reachable but returns a logical failure.
    private class FailBodyMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse r = new HttpResponse();
            r.setStatusCode(200);
            r.setBody('{"success":false,"message":"provider not connected"}');
            return r;
        }
    }

    // Transport-level failure (non-2xx).
    private class Http500Mock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse r = new HttpResponse();
            r.setStatusCode(500);
            r.setBody('boom');
            return r;
        }
    }

    private static void setup() {
        SignForceConfigService.lambdaEndpointOverride = 'https://lambda.test/signforce';
        SignForce_Admin_Config__c cs = SignForce_Admin_Config__c.getOrgDefaults();
        cs.Google_Client_ID__c = 'gid';
        cs.Google_Client_Secret__c = 'gsecret';
        cs.Microsoft_Client_ID__c = 'mid';
        cs.Microsoft_Client_Secret__c = 'msecret';
        upsert cs;
    }

    @isTest
    static void listGoogleFolders_success() {
        setup();
        Test.setMock(HttpCalloutMock.class, new OkMock());
        Test.startTest();
        SignForceAdminConfigController.FolderResult r = SignForceAdminConfigController.listGoogleFolders();
        Test.stopTest();
        System.assertEquals(true, r.success, 'msg=' + r.message);
        System.assertEquals(2, r.folders.size(), 'Both folders parsed');
        System.assertEquals('Alpha', r.folders[0].name);
    }

    @isTest
    static void listGoogleFolders_providerFailure() {
        setup();
        Test.setMock(HttpCalloutMock.class, new FailBodyMock());
        Test.startTest();
        SignForceAdminConfigController.FolderResult r = SignForceAdminConfigController.listGoogleFolders();
        Test.stopTest();
        System.assertEquals(false, r.success);
        System.assertEquals('provider not connected', r.message);
    }

    @isTest
    static void listGoogleFolders_httpError() {
        setup();
        Test.setMock(HttpCalloutMock.class, new Http500Mock());
        Test.startTest();
        SignForceAdminConfigController.FolderResult r = SignForceAdminConfigController.listGoogleFolders();
        Test.stopTest();
        System.assertEquals(false, r.success);
        System.assert(r.message.contains('500'), 'HTTP code surfaced: ' + r.message);
    }

    @isTest
    static void listOneDriveFolders_success() {
        setup();
        Test.setMock(HttpCalloutMock.class, new OkMock());
        Test.startTest();
        SignForceAdminConfigController.FolderResult r = SignForceAdminConfigController.listOneDriveFolders();
        Test.stopTest();
        System.assertEquals(true, r.success, 'msg=' + r.message);
        System.assertEquals(2, r.folders.size());
    }

    @isTest
    static void listOneDriveFolders_httpError() {
        setup();
        Test.setMock(HttpCalloutMock.class, new Http500Mock());
        Test.startTest();
        SignForceAdminConfigController.FolderResult r = SignForceAdminConfigController.listOneDriveFolders();
        Test.stopTest();
        System.assertEquals(false, r.success);
    }

    @isTest
    static void createGoogleFolder_success() {
        setup();
        Test.setMock(HttpCalloutMock.class, new OkMock());
        Test.startTest();
        SignForceAdminConfigController.FolderResult r =
            SignForceAdminConfigController.createGoogleFolder('New Folder', 'root');
        Test.stopTest();
        System.assertEquals(true, r.success, 'msg=' + r.message);
        System.assertEquals('nf-1', r.folderId);
        System.assertEquals('New Folder', r.folderName);
    }

    @isTest
    static void createGoogleFolder_providerFailure() {
        setup();
        Test.setMock(HttpCalloutMock.class, new FailBodyMock());
        Test.startTest();
        SignForceAdminConfigController.FolderResult r =
            SignForceAdminConfigController.createGoogleFolder('X', null);
        Test.stopTest();
        System.assertEquals(false, r.success);
    }

    @isTest
    static void createOneDriveFolder_success() {
        setup();
        Test.setMock(HttpCalloutMock.class, new OkMock());
        Test.startTest();
        SignForceAdminConfigController.FolderResult r =
            SignForceAdminConfigController.createOneDriveFolder('New Folder', 'root');
        Test.stopTest();
        System.assertEquals(true, r.success, 'msg=' + r.message);
        System.assertEquals('nf-1', r.folderId);
    }

    @isTest
    static void createOneDriveFolder_httpError() {
        setup();
        Test.setMock(HttpCalloutMock.class, new Http500Mock());
        Test.startTest();
        SignForceAdminConfigController.FolderResult r =
            SignForceAdminConfigController.createOneDriveFolder('X', null);
        Test.stopTest();
        System.assertEquals(false, r.success);
    }

    @isTest
    static void disconnectIntegration_success() {
        setup();
        Test.setMock(HttpCalloutMock.class, new OkMock());
        Test.startTest();
        SignForceAdminConfigController.IntegrationActionResult r =
            SignForceAdminConfigController.disconnectIntegration('GoogleDrive');
        Test.stopTest();
        System.assertEquals(true, r.success, 'msg=' + r.message);
    }

    @isTest
    static void disconnectIntegration_httpError() {
        setup();
        Test.setMock(HttpCalloutMock.class, new Http500Mock());
        Test.startTest();
        SignForceAdminConfigController.IntegrationActionResult r =
            SignForceAdminConfigController.disconnectIntegration('OneDrive');
        Test.stopTest();
        System.assertEquals(false, r.success);
    }

    @isTest
    static void hasAdminAccess_returnsBoolean() {
        // The test-running user is a System Administrator -> has Customize Application.
        Test.startTest();
        Boolean admin = SignForceAdminConfigController.hasAdminAccess();
        Test.stopTest();
        System.assertEquals(true, admin, 'Admin running the test should have access');
    }

    @isTest
    static void mapSites_skipsArchivedAndInactiveSites() {
        // DomainSite/Domain aren't insertable, so build the rows in memory.
        List<DomainSite> rows = new List<DomainSite>{
            // Active LWR site -> must appear
            (DomainSite) JSON.deserialize(
                '{"PathPrefix":"sign","Domain":{"Domain":"live.my.site.com"},'
                + '"Site":{"Name":"Live","SiteType":"ChatterNetworkPicasso","Status":"Active"}}',
                DomainSite.class),
            // Archived / deactivated site -> must be hidden (its URL serves nothing)
            (DomainSite) JSON.deserialize(
                '{"PathPrefix":"old","Domain":{"Domain":"archived.my.site.com"},'
                + '"Site":{"Name":"Archived","SiteType":"ChatterNetworkPicasso","Status":"Inactive"}}',
                DomainSite.class),
            // Status unknown -> shown rather than silently dropped
            (DomainSite) JSON.deserialize(
                '{"PathPrefix":"unknown","Domain":{"Domain":"nostatus.my.site.com"},'
                + '"Site":{"Name":"No Status","SiteType":"ChatterNetworkPicasso"}}',
                DomainSite.class)
        };

        Test.startTest();
        List<SignForceAdminConfigController.Option> opts =
            SignForceAdminConfigController.mapSites(rows);
        Test.stopTest();

        System.assertEquals(2, opts.size(), 'Only the archived site should be dropped');
        for (SignForceAdminConfigController.Option o : opts) {
            System.assert(!o.value.contains('archived.my.site.com'),
                'Archived site must not be selectable: ' + o.value);
        }
        System.assertEquals('https://live.my.site.com/sign', opts[0].value);
        System.assertEquals('https://nostatus.my.site.com/unknown', opts[1].value);
    }

    @isTest
    static void getAssignedGuestUserIds_unknownSetIsEmpty() {
        Test.startTest();
        List<Id> ids = SignForceAdminConfigController.getAssignedGuestUserIds('Not_A_Package_Set');
        Test.stopTest();
        System.assertEquals(0, ids.size(), 'Non-package perm set returns empty list');
    }
}