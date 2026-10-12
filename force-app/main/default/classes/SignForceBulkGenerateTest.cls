/**
 * SignForceBulkGenerateTest — the bulk document run.
 *
 * These deliberately exercise the guards and the progress maths, not the render
 * itself: the Queueable calls DocumentGenerationService.generate(), which makes
 * an HTTP callout, and re-testing the merge here would only duplicate
 * DocumentGenerationServiceTest.
 *
 * The guards are the part worth pinning. Starting a hundred-record batch against
 * the wrong object, or against a template with no file, wastes a long
 * asynchronous run before anyone finds out — so all of it is rejected up front,
 * before a single job is queued.
 *
 * No ContentVersion is created anywhere in here. Template_File_Id__c only has to
 * be non-blank for the guard, and file creation counts against an org-wide
 * publication limit that a test suite should not be spending.
 */
@IsTest
private class SignForceBulkGenerateTest {

    private static Document_Template__c activeTemplate(String objectApi) {
        Document_Template__c tpl = DocGenTestDataFactory.makeTemplate(
            'Bulk Tpl', objectApi, 'DOCX', false
        );
        tpl.Template_File_Id__c = '069000000000000AAA';   // stand-in, never read here
        update tpl;
        return tpl;
    }

    private static List<Account> makeAccounts(Integer n) {
        List<Account> accts = new List<Account>();
        for (Integer i = 0; i < n; i++) accts.add(new Account(Name = 'Bulk Co ' + i));
        insert accts;
        return accts;
    }

    private static Document_Generation_Log__c logFor(Id tplId, Id recordId, String status) {
        Document_Generation_Log__c log = new Document_Generation_Log__c(
            Document_Template__c      = tplId,
            Source_Record_Id__c       = recordId,
            Source_Object_Api_Name__c = 'Account',
            Status__c                 = status,
            Output_Filename__c        = 'Doc.docx'
        );
        insert log;
        return log;
    }

    private static String messageOf(Exception e) {
        return e.getMessage() == null ? '' : e.getMessage();
    }

    /* ── guards ───────────────────────────────────────────────────── */

    @IsTest
    static void noTemplate_isRejected() {
        Boolean threw = false;
        Test.startTest();
        try { SignForceBulkGenerate.startBulkGenerate(null, new List<Id>{ '001000000000000AAA' }); }
        catch (Exception e) { threw = true; }
        Test.stopTest();
        Assert.isTrue(threw, 'A batch with no template must be refused');
    }

    @IsTest
    static void noRecords_isRejected() {
        Document_Template__c tpl = activeTemplate('Account');
        Boolean threw = false;
        Test.startTest();
        try { SignForceBulkGenerate.startBulkGenerate(tpl.Id, new List<Id>()); }
        catch (Exception e) { threw = true; }
        Test.stopTest();
        Assert.isTrue(threw, 'A batch with no records must be refused');
    }

    /**
     * The expensive mistake: a template built for Account, run over Contacts.
     * Every record would fail individually after a long async run.
     */
    @IsTest
    static void wrongObject_isRejectedBeforeQueueing() {
        Document_Template__c tpl = activeTemplate('Account');
        Contact c = new Contact(LastName = 'Wrong Object');
        insert c;

        String msg = '';
        Test.startTest();
        try {
            SignForceBulkGenerate.startBulkGenerate(tpl.Id, new List<Id>{ c.Id });
        } catch (Exception e) {
            msg = messageOf(e);
        }
        Test.stopTest();

        Assert.isTrue(msg.length() > 0, 'A Contact under an Account template must be refused');
        Assert.areEqual(0, [SELECT COUNT() FROM AsyncApexJob WHERE JobType = 'Queueable'],
            'Nothing should be queued when validation fails');
    }

    @IsTest
    static void inactiveTemplate_isRejected() {
        Document_Template__c tpl = activeTemplate('Account');
        tpl.Active__c = false;
        update tpl;
        Account a = makeAccounts(1)[0];

        Boolean threw = false;
        Test.startTest();
        try { SignForceBulkGenerate.startBulkGenerate(tpl.Id, new List<Id>{ a.Id }); }
        catch (Exception e) { threw = true; }
        Test.stopTest();
        Assert.isTrue(threw, 'An inactive template must not start a batch');
    }

    @IsTest
    static void templateWithoutFile_isRejected() {
        Document_Template__c tpl = DocGenTestDataFactory.makeTemplate('No File', 'Account', 'DOCX', false);
        Account a = makeAccounts(1)[0];

        Boolean threw = false;
        Test.startTest();
        try { SignForceBulkGenerate.startBulkGenerate(tpl.Id, new List<Id>{ a.Id }); }
        catch (Exception e) { threw = true; }
        Test.stopTest();
        Assert.isTrue(threw, 'A template with no uploaded document must not start a batch');
    }

    /* ── progress ─────────────────────────────────────────────────── */

    /**
     * Progress is read from the logs, so it has to count DISTINCT records: a
     * record retried after a failure writes two rows but is still one record.
     */
    @IsTest
    static void statusCountsRecordsNotRows() {
        Document_Template__c tpl = activeTemplate('Account');
        List<Account> accts = makeAccounts(3);
        List<Id> ids = new List<Id>{ accts[0].Id, accts[1].Id, accts[2].Id };

        Datetime started = Datetime.now().addMinutes(-1);
        logFor(tpl.Id, accts[0].Id, 'Failure');
        logFor(tpl.Id, accts[0].Id, 'Success');   // same record, retried
        logFor(tpl.Id, accts[1].Id, 'Failure');

        Test.startTest();
        Map<String, Object> s = SignForceBulkGenerate.getGenerateStatus(
            tpl.Id, ids, started.format('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'', 'GMT')
        );
        Test.stopTest();

        Assert.areEqual(3, s.get('total'), 'Total is what was asked for');
        Assert.areEqual(1, s.get('succeeded'), 'The retried record counts once, as a success');
        Assert.areEqual(1, s.get('failed'), 'The record that only ever failed counts as failed');
        Assert.areEqual(2, s.get('done'), 'Two of three records have an outcome');
        Assert.areEqual(false, s.get('finished'), 'One record is still outstanding');
    }

    /**
     * Without the start time, a record generated last week would report as done
     * the instant a new batch begins.
     */
    @IsTest
    static void statusIgnoresLogsFromBeforeTheBatch() {
        Document_Template__c tpl = activeTemplate('Account');
        Account a = makeAccounts(1)[0];
        logFor(tpl.Id, a.Id, 'Success');

        // A batch that starts in a minute's time cannot have anything done yet.
        String future = Datetime.now().addMinutes(1)
            .format('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'', 'GMT');

        Test.startTest();
        Map<String, Object> s = SignForceBulkGenerate.getGenerateStatus(
            tpl.Id, new List<Id>{ a.Id }, future
        );
        Test.stopTest();

        Assert.areEqual(0, s.get('done'), 'An earlier generation must not count toward this batch');
        Assert.areEqual(false, s.get('finished'), 'Nothing has run yet');
    }

    @IsTest
    static void statusReportsFinishedWhenEveryRecordIsAccountedFor() {
        Document_Template__c tpl = activeTemplate('Account');
        List<Account> accts = makeAccounts(2);
        Datetime started = Datetime.now().addMinutes(-1);
        logFor(tpl.Id, accts[0].Id, 'Success');
        logFor(tpl.Id, accts[1].Id, 'Success');

        Test.startTest();
        Map<String, Object> s = SignForceBulkGenerate.getGenerateStatus(
            tpl.Id, new List<Id>{ accts[0].Id, accts[1].Id },
            started.format('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'', 'GMT')
        );
        Test.stopTest();

        Assert.areEqual(true, s.get('finished'), 'Every record has an outcome, so the batch is done');
        Assert.areEqual(2, s.get('succeeded'), 'Both succeeded');
    }

    @IsTest
    static void statusWithNoRecords_returnsEmptyRatherThanThrowing() {
        Document_Template__c tpl = activeTemplate('Account');

        Test.startTest();
        Map<String, Object> s = SignForceBulkGenerate.getGenerateStatus(tpl.Id, new List<Id>(), null);
        Test.stopTest();

        Assert.areEqual(0, s.get('total'), 'An empty request is answered, not rejected');
    }

    /* ── record picker ────────────────────────────────────────────── */

    @IsTest
    static void searchReturnsRecordsOfTheTemplatesObject() {
        Document_Template__c tpl = activeTemplate('Account');
        makeAccounts(2);
        insert new Account(Name = 'Findable Widgets Ltd');

        Test.startTest();
        List<Map<String, Object>> all = SignForceBulkGenerate.searchRecords(tpl.Id, null);
        List<Map<String, Object>> hit = SignForceBulkGenerate.searchRecords(tpl.Id, 'Findable');
        Test.stopTest();

        Assert.isTrue(all.size() >= 3, 'A blank term lists recent records so the picker is never empty');
        Assert.areEqual(1, hit.size(), 'The search term should narrow the list');
        Assert.areEqual('Findable Widgets Ltd', hit[0].get('name'), 'And return the matching record');
    }

    /* ── object detection (what the flow screen relies on) ────────── */

    @IsTest
    static void describeIds_reportsTheObjectBehindTheIds() {
        List<Account> accts = makeAccounts(2);

        Test.startTest();
        Map<String, Object> info = SignForceBulkGenerate.describeIds(
            new List<Id>{ accts[0].Id, accts[1].Id }
        );
        Test.stopTest();

        Assert.areEqual('Account', info.get('objectApiName'),
            'The flow screen derives the object from the ids alone');
        Assert.areEqual(2, info.get('count'), 'And how many there are');
        Assert.isNotNull(info.get('objectLabelPlural'), 'Plural label is what the UI prints');
    }

    @IsTest
    static void describeIds_rejectsAMixedSelection() {
        Account a = makeAccounts(1)[0];
        Contact c = new Contact(LastName = 'Mixed');
        insert c;

        Boolean threw = false;
        Test.startTest();
        try { SignForceBulkGenerate.describeIds(new List<Id>{ a.Id, c.Id }); }
        catch (Exception e) { threw = true; }
        Test.stopTest();

        Assert.isTrue(threw,
            'Ids of two different objects cannot be one batch and must be refused');
    }

    @IsTest
    static void describeIds_emptyList_returnsZeroCount() {
        Test.startTest();
        Map<String, Object> info = SignForceBulkGenerate.describeIds(new List<Id>());
        Test.stopTest();
        Assert.areEqual(0, info.get('count'), 'An empty selection is answered, not rejected');
    }

    @IsTest
    static void searchWithoutTemplate_returnsNothing() {
        Test.startTest();
        List<Map<String, Object>> rows = SignForceBulkGenerate.searchRecords(null, 'anything');
        Test.stopTest();
        Assert.areEqual(0, rows.size(), 'No template means nothing to search against');
    }
}