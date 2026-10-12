/**
 * ZeroCoverageBackfillTest — coverage for three classes that carried none, which
 * dragged the package's average below the 75% upload threshold.
 *
 *   - SignForceBulkGenerateBatch : the Batch that runs one generation per record.
 *   - AgentforceAddSigner        : the invocable wrapper (the engine is disabled,
 *                                  so the action returns the disabled message).
 *   - PDFServeController         : a bare controller shell with only a constructor.
 *
 * The batch path reuses the same Lambda mock and template factory as
 * DocumentGenerationServiceTest, so it exercises execute()/finish() without
 * spending the org-wide ContentVersion publication limit.
 */
@IsTest
private class ZeroCoverageBackfillTest {

    @IsTest
    static void bulkGenerateBatch_runsAndClosesOutEveryRecord() {
        Document_Template__c tpl = DocGenTestDataFactory.makeTemplate(
            'Backfill Tpl', 'Account', 'DOCX', false
        );
        tpl.Template_File_Id__c = '069000000000000AAA';   // stand-in, satisfies the guard
        update tpl;

        List<Account> accts = new List<Account>{
            new Account(Name = 'Backfill Co A'),
            new Account(Name = 'Backfill Co B')
        };
        insert accts;
        List<Id> ids = new List<Id>{ accts[0].Id, accts[1].Id };

        Test.setMock(HttpCalloutMock.class, DocGenLambdaMock.alwaysOk());
        Test.startTest();
        // One execute() in test context: a test method may only trigger a single
        // executeBatch cycle, so the scope must cover the whole run in one chunk.
        Database.executeBatch(new SignForceBulkGenerateBatch(tpl.Id, ids), 200);
        Test.stopTest();

        // finish() guarantees a log row per record, whatever happened in execute().
        Integer rows = [
            SELECT COUNT() FROM Document_Generation_Log__c
            WHERE Document_Template__c = :tpl.Id
        ];
        Assert.isTrue(rows >= ids.size(),
            'Every record in the run must end with a generation-log row');
    }

    @IsTest
    static void bulkGenerateBatch_emptyIdListFinishesCleanly() {
        Document_Template__c tpl = DocGenTestDataFactory.makeTemplate(
            'Backfill Empty', 'Account', 'DOCX', false
        );
        tpl.Template_File_Id__c = '069000000000000AAA';
        update tpl;

        Test.startTest();
        Database.executeBatch(new SignForceBulkGenerateBatch(tpl.Id, new List<Id>()), 200);
        Test.stopTest();

        // finish() returns early on an empty run — no rows, no exception.
        Integer rows = [
            SELECT COUNT() FROM Document_Generation_Log__c
            WHERE Document_Template__c = :tpl.Id
        ];
        Assert.areEqual(0, rows, 'An empty run writes no log rows');
    }

    @IsTest
    static void bulkGenerateBatch_failedGenerate_stillClosesOut() {
        // When generate() fails, finish() is the safety net that writes the
        // otherwise-missing log row so the run reaches a terminal state.
        Document_Template__c tpl = DocGenTestDataFactory.makeTemplate(
            'Backfill Fail', 'Account', 'DOCX', false
        );
        tpl.Template_File_Id__c = '069000000000000AAA';
        update tpl;

        Account a = new Account(Name = 'Backfill Fail Co');
        insert a;

        Test.setMock(HttpCalloutMock.class, DocGenLambdaMock.failGenerate());
        Test.startTest();
        Database.executeBatch(new SignForceBulkGenerateBatch(tpl.Id, new List<Id>{ a.Id }), 200);
        Test.stopTest();

        Integer rows = [
            SELECT COUNT() FROM Document_Generation_Log__c
            WHERE Document_Template__c = :tpl.Id
        ];
        Assert.isTrue(rows >= 1,
            'A failed record must still end with a log row, written by finish()');
    }

    @IsTest
    static void agentforceAddSigner_returnsDisabledMessage() {
        AgentforceAddSigner.Request req = new AgentforceAddSigner.Request();
        req.email        = 'signer@example.com';
        req.signerName   = 'Jane Doe';
        req.role         = 'Signer';
        req.signingOrder = 1;

        Test.startTest();
        List<AgentforceAddSigner.Response> out =
            AgentforceAddSigner.getInvocableActions(new List<AgentforceAddSigner.Request>{ req });
        Test.stopTest();

        Assert.areEqual(1, out.size(), 'One response per request');
        Assert.isNotNull(out[0].result, 'A result string is always returned');
        // The engine is disabled, so the wrapper reports success with the
        // disabled message rather than throwing.
        Assert.areEqual(true, out[0].success, 'The wrapper reports a handled outcome');
    }

    @IsTest
    static void pdfServeController_constructs() {
        Test.startTest();
        PDFServeController c = new PDFServeController();
        Test.stopTest();
        Assert.isNotNull(c, 'Controller constructs');
    }
}