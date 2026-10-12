@isTest
private class SignForceCloudPushQueueableTest {

    private class PushMock implements HttpCalloutMock {
        Integer calls = 0;
        Integer folderCalls = 0;
        public HttpResponse respond(HttpRequest req) {
            calls++;
            HttpResponse res = new HttpResponse();
            res.setHeader('Content-Type', 'application/json');
            res.setStatusCode(200);
            if (req.getBody() != null && req.getBody().contains('createGoogleFolder')) {
                folderCalls++;
                res.setBody('{"success":true,"folderId":"fold123"}');
            } else {
                res.setBody('{"success":true,"externalId":"file123"}');
            }
            return res;
        }
    }

    private static Id makeFile(String name) {
        ContentVersion cv = new ContentVersion(
            Title = name, PathOnClient = name, VersionData = Blob.valueOf('bytes')
        );
        insert cv;
        return cv.Id;
    }

    @isTest
    static void skipsWhenNoProviderEnabled() {
        Id cvId = makeFile('doc.pdf');
        Test.startTest();
        System.enqueueJob(new SignForceCloudPushQueueable(cvId));
        Test.stopTest();
        // No provider configured -> anyEnabled() false -> execute returns before
        // any callout; finishing without "callout not allowed" is the assertion.
        System.assertEquals(0, [SELECT COUNT() FROM AsyncApexJob WHERE Status = 'Failed' AND ApexClass.Name = 'SignForceCloudPushQueueable']);
    }

    @isTest
    static void pushesToEnabledProvider() {
        SignForce_Admin_Config__c cfg = SignForce_Admin_Config__c.getOrgDefaults();
        cfg.Integration_GoogleDrive_Enabled__c = true;
        cfg.Integration_GoogleDrive_Target__c = 'folder123';
        upsert cfg;

        Id cvId = makeFile('agreement.docx');
        PushMock mock = new PushMock();
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        System.enqueueJob(new SignForceCloudPushQueueable(new List<Id>{ cvId }));
        Test.stopTest();

        System.assert(mock.calls >= 1, 'Expected a cloud push callout, got ' + mock.calls);
    }

    @isTest
    static void createsSubfolderAndCachesId() {
        SignForce_Admin_Config__c cfg = SignForce_Admin_Config__c.getOrgDefaults();
        cfg.Integration_GoogleDrive_Enabled__c = true;
        cfg.Integration_GoogleDrive_Target__c = 'folder123';
        upsert cfg;

        Id cvId = makeFile('generated.pdf');
        PushMock mock = new PushMock();
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        System.enqueueJob(new SignForceCloudPushQueueable(cvId, 'Contact'));
        Test.stopTest();

        System.assertEquals(1, mock.folderCalls, 'Expected one createGoogleFolder callout');
        System.assert(mock.calls >= 2, 'Expected folder + push callouts, got ' + mock.calls);
        SignForce_Admin_Config__c after = SignForce_Admin_Config__c.getOrgDefaults();
        System.assert(String.isNotBlank(after.Integration_Config_JSON__c)
            && after.Integration_Config_JSON__c.contains('fold123'),
            'Folder id should be cached in Integration_Config_JSON__c');
    }

    @isTest
    static void emptyListIsANoOp() {
        Test.startTest();
        System.enqueueJob(new SignForceCloudPushQueueable(new List<Id>()));
        Test.stopTest();
        System.assertEquals(0, [SELECT COUNT() FROM AsyncApexJob WHERE Status = 'Failed' AND ApexClass.Name = 'SignForceCloudPushQueueable']);
    }

    @isTest
    static void contentTypes() {
        System.assertEquals('application/pdf', SignForceCloudPushQueueable.contentTypeFor('pdf'));
        System.assertEquals(
            'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
            SignForceCloudPushQueueable.contentTypeFor('DOCX'));
        System.assertEquals('application/msword', SignForceCloudPushQueueable.contentTypeFor('doc'));
        System.assertEquals('application/octet-stream', SignForceCloudPushQueueable.contentTypeFor(null));
        System.assertEquals('application/octet-stream', SignForceCloudPushQueueable.contentTypeFor('png'));
    }
}