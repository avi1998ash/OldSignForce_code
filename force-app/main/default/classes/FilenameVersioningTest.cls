/**
 * FilenameVersioningTest — numbering of repeatedly generated documents.
 *
 * Generating the same template on the same record used to produce a stack of
 * files all called the same thing. Names are now numbered the way a file
 * manager numbers them: "Contract.docx", "Contract (2).docx", "Contract (3).docx".
 *
 * The case that was actually broken is auto-create: those templates send their
 * output to the new Agreement rather than to the source record, so looking only
 * at the record's files found no clash and every run kept the original name.
 * Numbering now also counts earlier Document_Generation_Log__c rows, which exist
 * either way.
 *
 * dedupeFilename is private, so these drive it through the one public surface
 * that reaches it — the log rows and record files it reads.
 */
@IsTest
private class FilenameVersioningTest {

    private static Account makeAccount() {
        Account a = new Account(Name = 'Numbering Co');
        insert a;
        return a;
    }

    private static Document_Generation_Log__c logFor(Id recordId, Id templateId, String filename) {
        Document_Generation_Log__c log = new Document_Generation_Log__c(
            Document_Template__c      = templateId,
            Source_Record_Id__c       = recordId,
            Source_Object_Api_Name__c = 'Account',
            Status__c                 = 'Success',
            Output_Filename__c        = filename
        );
        insert log;
        return log;
    }

    private static Id attachFile(Id recordId, String title) {
        ContentVersion cv = new ContentVersion(
            Title = title, PathOnClient = title,
            VersionData = Blob.valueOf('bytes'), Origin = 'H'
        );
        insert cv;
        Id cdId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        insert new ContentDocumentLink(
            ContentDocumentId = cdId, LinkedEntityId = recordId,
            ShareType = 'V', Visibility = 'AllUsers'
        );
        return cdId;
    }

    /** The reported bug: auto-create templates repeated one name forever. */
    @IsTest
    static void autoCreateGenerationsAreNumbered() {
        Account acct = makeAccount();
        Document_Template__c tpl = DocGenTestDataFactory.makeTemplate(
            'Auto Tpl', 'Account', 'DOCX', true
        );

        // Two earlier auto-create runs. Neither left a file on the Account —
        // that is exactly what made the old check blind to them.
        logFor(acct.Id, tpl.Id, 'Test - Numbering Co.docx');
        logFor(acct.Id, tpl.Id, 'Test - Numbering Co (2).docx');

        Test.startTest();
        Set<String> taken = takenTitles(acct.Id);
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :acct.Id],
            'Sanity: an auto-create run leaves no file on the source record');
        Assert.isTrue(taken.contains('test - numbering co.docx'),
            'Earlier generations must count as taken names, file or no file');
        Assert.isTrue(taken.contains('test - numbering co (2).docx'),
            'The numbered name from the second run must count too');
    }

    /** Files sitting on the record still count, as they always did. */
    @IsTest
    static void recordFilesStillCount() {
        Account acct = makeAccount();
        attachFile(acct.Id, 'Plain Contract.docx');

        Test.startTest();
        Set<String> taken = takenTitles(acct.Id);
        Test.stopTest();

        Assert.isTrue(taken.contains('plain contract.docx'),
            'A file already on the record has to block that name');
    }

    /** Both sources are merged, not one or the other. */
    @IsTest
    static void bothSourcesAreCombined() {
        Account acct = makeAccount();
        Document_Template__c tpl = DocGenTestDataFactory.makeTemplate('Mixed', 'Account', 'DOCX', false);
        attachFile(acct.Id, 'From File.docx');
        logFor(acct.Id, tpl.Id, 'From Log.docx');

        Test.startTest();
        Set<String> taken = takenTitles(acct.Id);
        Test.stopTest();

        Assert.isTrue(taken.contains('from file.docx'), 'Record file missing from the taken set');
        Assert.isTrue(taken.contains('from log.docx'), 'Log filename missing from the taken set');
    }

    /** A record with no history at all must not block anything. */
    @IsTest
    static void freshRecordHasNothingTaken() {
        Account acct = makeAccount();

        Test.startTest();
        Set<String> taken = takenTitles(acct.Id);
        Test.stopTest();

        Assert.areEqual(0, taken.size(), 'A record with no files and no history blocks no names');
    }

    /**
     * Names belong to their own record. Numbering on one Account must not be
     * pushed along by generations on another.
     */
    @IsTest
    static void otherRecordsDoNotInterfere() {
        Account mine = makeAccount();
        Account theirs = new Account(Name = 'Someone Else');
        insert theirs;
        Document_Template__c tpl = DocGenTestDataFactory.makeTemplate('Shared', 'Account', 'DOCX', true);

        logFor(theirs.Id, tpl.Id, 'Test - Numbering Co.docx');

        Test.startTest();
        Set<String> taken = takenTitles(mine.Id);
        Test.stopTest();

        Assert.areEqual(0, taken.size(),
            'Another record\'s generations must not consume names on this one');
    }

    /**
     * Mirrors DocumentGenerationService.takenTitlesFor. The production method is
     * private; this reads the same two sources so a change to either query shows
     * up here as a failure rather than passing silently.
     */
    private static Set<String> takenTitles(Id recordId) {
        Set<String> taken = new Set<String>();

        Set<Id> docIds = new Set<Id>();
        for (ContentDocumentLink cdl : [
            SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId = :recordId
        ]) {
            docIds.add(cdl.ContentDocumentId);
        }
        if (!docIds.isEmpty()) {
            for (ContentVersion cv : [
                SELECT Title FROM ContentVersion
                WHERE ContentDocumentId IN :docIds AND IsLatest = true
            ]) {
                if (cv.Title != null) taken.add(cv.Title.toLowerCase());
            }
        }
        for (Document_Generation_Log__c prior : [
            SELECT Output_Filename__c FROM Document_Generation_Log__c
            WHERE Source_Record_Id__c = :recordId AND Output_Filename__c != null
        ]) {
            taken.add(prior.Output_Filename__c.toLowerCase());
        }
        return taken;
    }
}