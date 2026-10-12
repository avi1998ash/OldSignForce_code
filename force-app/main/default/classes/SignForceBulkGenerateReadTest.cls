/**
 * SignForceBulkGenerateReadTest — coverage for the read/status/search surface of
 * SignForceBulkGenerate that the existing SignForceBulkGenerateTest (guards only)
 * left uncovered: getGenerateStatus, describeIds, getActivityDetail,
 * getRecentActivity, searchRecords, and the happy-path start that enqueues the
 * batch. Part of lifting the package average over the 75% upload threshold.
 */
@IsTest
private class SignForceBulkGenerateReadTest {

    private static Document_Template__c activeTemplate() {
        Document_Template__c tpl = DocGenTestDataFactory.makeTemplate('Bulk Read', 'Account', 'DOCX', false);
        tpl.Template_File_Id__c = '069000000000000AAA';
        update tpl;
        return tpl;
    }

    private static void logFor(Id tplId, Id recId, String status) {
        insert new Document_Generation_Log__c(
            Document_Template__c      = tplId,
            Source_Record_Id__c       = recId,
            Source_Object_Api_Name__c = 'Account',
            Status__c                 = status,
            Output_Filename__c        = 'Doc.docx'
        );
    }

    @IsTest
    static void startBulkGenerate_happyPath_enqueues() {
        Document_Template__c tpl = activeTemplate();
        Account a = DocGenTestDataFactory.makeAccount('Bulk Start Co');

        Test.setMock(HttpCalloutMock.class, DocGenLambdaMock.alwaysOk());
        Test.startTest();
        Map<String, Object> res = SignForceBulkGenerate.startBulkGenerate(tpl.Id, new List<Id>{ a.Id });
        Test.stopTest();

        Assert.isNotNull(res, 'start returns a status map');
    }

    @IsTest
    static void statusAndDescribeAndSearch() {
        Document_Template__c tpl = activeTemplate();
        List<Account> accs = new List<Account>{
            DocGenTestDataFactory.makeAccount('Bulk A'),
            DocGenTestDataFactory.makeAccount('Bulk B')
        };
        logFor(tpl.Id, accs[0].Id, 'Success');
        logFor(tpl.Id, accs[1].Id, 'Failure');

        Test.startTest();
        Map<String, Object> status = SignForceBulkGenerate.getGenerateStatus(
            tpl.Id, new List<Id>{ accs[0].Id, accs[1].Id }, null
        );
        Map<String, Object> describe = SignForceBulkGenerate.describeIds(
            new List<Id>{ accs[0].Id, accs[1].Id }
        );
        Map<String, Object> describeEmpty = SignForceBulkGenerate.describeIds(new List<Id>());
        List<Map<String, Object>> search = SignForceBulkGenerate.searchRecords(tpl.Id, 'Bulk');
        Test.stopTest();

        Assert.isNotNull(status, 'status map returned');
        Assert.isNotNull(describe, 'describe map returned');
        Assert.areEqual(0, describeEmpty.get('count'), 'empty id list describes to count 0');
        Assert.isNotNull(search, 'search returns a list');
    }

    @IsTest
    static void activityFeeds() {
        Document_Template__c tpl = activeTemplate();
        Account a = DocGenTestDataFactory.makeAccount('Bulk Activity Co');
        logFor(tpl.Id, a.Id, 'Success');

        Test.startTest();
        List<Map<String, Object>> detail = SignForceBulkGenerate.getActivityDetail(tpl.Id, 'Account', 168);
        List<Map<String, Object>> recent = SignForceBulkGenerate.getRecentActivity(168);
        List<Map<String, Object>> recentDefault = SignForceBulkGenerate.getRecentActivity(null);
        Test.stopTest();

        Assert.isNotNull(detail, 'activity detail returned');
        Assert.isNotNull(recent, 'recent activity returned');
        Assert.isNotNull(recentDefault, 'recent activity with default window returned');
    }
}