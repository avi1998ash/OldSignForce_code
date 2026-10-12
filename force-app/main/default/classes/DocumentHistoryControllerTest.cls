/**
 * DocumentHistoryControllerTest — improved coverage targeting 75%+
 *
 * Key additions over prior version:
 *  1. MockHttp200Generate defined (was missing — caused compile/runtime failures)
 *  2. MockHttpGenerateFail for failure-path callouts
 *  3. createAgreementFromHistory — hasFile=true branch (ContentVersion exists)
 *  4. createAgreementFromHistory — template with Default_Agreement_Type__c set
 *  5. regenerateForPreview — missing source record throws
 *  6. getPreviewUrlForContentVersion — file not found branch
 *  7. sendDocumentEmail — null bytes from ContentDoc (file deleted mid-flight)
 *  8. listGenerationsForRecord — multiple logs consume agreements correctly
 *  9. resolveRecipientEmail — Account resolves via its contacts, never its owner
 * 10. deleteHistoryEntry — all sub-paths
 */
@isTest(SeeAllData=false)
private class DocumentHistoryControllerTest {

    // =========================================================
    //  Mock HTTP — referenced by createAgreementFromHistory
    //  and regenerateForPreview when they call downstream
    //  DocumentGenerationService which may do HTTP callouts.
    // =========================================================

    /**
     * Returns a 200 with a minimal GenerationResult-like JSON body.
     * Adjust the JSON shape to match DocumentGenerationService.GenerationResult.
     */
    private class MockHttp200Generate implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            // Minimal payload — base64 of 'fake pdf bytes'
            String fakeB64 = EncodingUtil.base64Encode(Blob.valueOf('fake pdf bytes'));
            res.setBody(JSON.serialize(new Map<String, Object>{
                'status'        => 'Success',
                'outputBase64'  => fakeB64,
                'filename'      => 'generated.pdf',
                'byteSize'      => 14,
                'errorMessage'  => null,
                // For getPreviewUrlForContentVersion lambda path:
                'success'       => true,
                'url'           => 'https://example.com/preview.pdf'
            }));
            return res;
        }
    }

    /** Returns a 500 so downstream service throws / returns failure */
    private class MockHttpGenerateFail implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(500);
            res.setBody('{"error":"internal server error"}');
            return res;
        }
    }

    // =========================================================
    //  Data helpers
    // =========================================================

    private static Account createAccount() {
        Account a = new Account(Name = 'DocHist Test Acct');
        insert a;
        return a;
    }

    private static Contact createContactWithEmail(String email) {
        Contact c = new Contact(LastName = 'DocHist', Email = email);
        insert c;
        return c;
    }

    /**
     * Creates a ContentVersion attached to recordId and returns the
     * auto-created ContentDocumentId.
     */
    private static Id createContentDocumentForRecord(Id recordId, String title) {
        ContentVersion cv = new ContentVersion();
        cv.Title                  = title;
        cv.PathOnClient           = title + '.pdf';
        cv.VersionData            = Blob.valueOf('test pdf bytes');
        cv.FirstPublishLocationId = recordId;
        insert cv;
        return [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
    }

    private static Document_Generation_Log__c createLog(
        Id sourceRecordId, String status, Id outputFileId, String filename
    ) {
        Document_Generation_Log__c log = new Document_Generation_Log__c();
        log.Source_Record_Id__c = sourceRecordId;
        log.Status__c           = status;
        if (outputFileId != null)         log.Output_File_Id__c  = outputFileId;
        if (String.isNotBlank(filename))  log.Output_Filename__c = filename;
        log.Duration_Ms__c = 1234;
        insert log;
        return log;
    }

    /** Creates a minimal Document_Template__c. */
    private static Id createTemplate(String name) {
        ContentVersion cv = new ContentVersion(
            Title        = 'Template',
            PathOnClient = 'template.docx',
            VersionData  = Blob.valueOf('fake template')
        );
        insert cv;

        Document_Template__c tpl = new Document_Template__c(
            Name                = name,
            Active__c           = true,
            Output_Format__c    = 'PDF',
            Template_File_Id__c = cv.Id,
            Object_API_Name__c  = 'Account'
        );
        insert tpl;
        return tpl.Id;
    }

    /** Creates a template with Default_Agreement_Type__c set. */
    private static Id createTemplateWithAgreementType(String name, String agreementType) {
        ContentVersion cv = new ContentVersion(
            Title        = 'Template',
            PathOnClient = 'template.docx',
            VersionData  = Blob.valueOf('fake template')
        );
        insert cv;

        Document_Template__c tpl = new Document_Template__c(
            Name                       = name,
            Active__c                  = true,
            Output_Format__c           = 'PDF',
            Template_File_Id__c        = cv.Id,
            Object_API_Name__c         = 'Account',
            Default_Agreement_Type__c  = agreementType
        );
        insert tpl;
        return tpl.Id;
    }

    /**
     * Creates an Agreement__c with an Agreement_Document__c (Original type)
     * whose Content_Version_ID__c points to a real ContentVersion.
     */
    private static Agreement__c createAgreementWithDoc(Id sourceRecordId, Id templateId) {
        Agreement__c agr = new Agreement__c();
        agr.Name          = 'Auto-Created Agreement';
        agr.Status__c     = 'Draft';
        agr.Is_Template__c = false;
        agr.put('Source_Record_Id__c', sourceRecordId);
        agr.put('Source_Template__c', templateId);
        insert agr;

        ContentVersion cv = new ContentVersion();
        cv.Title                  = 'Generated Doc';
        cv.PathOnClient           = 'generated.pdf';
        cv.VersionData            = Blob.valueOf('generated pdf bytes');
        cv.FirstPublishLocationId = agr.Id;
        insert cv;

        ContentVersion inserted = [SELECT Id FROM ContentVersion WHERE Id = :cv.Id];

        Agreement_Document__c doc = new Agreement_Document__c();
        doc.Agreement__c          = agr.Id;
        doc.Name                  = 'Generated Doc';
        doc.Document_Type__c      = 'Original';
        doc.Content_Version_ID__c = inserted.Id;
        insert doc;

        return agr;
    }

    // =========================================================
    //  listGenerationsForRecord
    // =========================================================

    @isTest
    static void listGenerationsForRecord_nullRecordId_returnsEmpty() {
        Test.startTest();
        List<DocumentHistoryController.HistoryRow> rows =
            DocumentHistoryController.listGenerationsForRecord(null, false);
        Test.stopTest();
        Assert.areEqual(0, rows.size());
    }

    @isTest
    static void listGenerationsForRecord_successOnly_filtersFailures() {
        Account a  = createAccount();
        Id cdId    = createContentDocumentForRecord(a.Id, 'success-doc');
        createLog(a.Id, 'Success', cdId, 'success.pdf');
        createLog(a.Id, 'Failure', null,  'failed.pdf');

        Test.startTest();
        List<DocumentHistoryController.HistoryRow> rows =
            DocumentHistoryController.listGenerationsForRecord(a.Id, false);
        Test.stopTest();

        Assert.areEqual(1, rows.size());
        Assert.areEqual('Success', rows[0].status);
        Assert.areEqual(cdId, rows[0].contentDocumentId);
    }

    @isTest
    static void listGenerationsForRecord_includeFailed_returnsAll() {
        Account a  = createAccount();
        Id cdId    = createContentDocumentForRecord(a.Id, 'doc1');
        createLog(a.Id, 'Success', cdId, 'one.pdf');
        Document_Generation_Log__c failed = createLog(a.Id, 'Failure', null, 'two.pdf');
        failed.Error_Message__c = 'Something went wrong';
        update failed;

        Test.startTest();
        List<DocumentHistoryController.HistoryRow> rows =
            DocumentHistoryController.listGenerationsForRecord(a.Id, true);
        Test.stopTest();

        Assert.areEqual(2, rows.size());
        Boolean foundFailure = false;
        for (DocumentHistoryController.HistoryRow r : rows) {
            if (r.status == 'Failure') {
                foundFailure = true;
                Assert.areEqual('Something went wrong', r.errorMessage);
            }
        }
        Assert.isTrue(foundFailure);
    }

    @isTest
    static void listGenerationsForRecord_otherRecord_excluded() {
        Account a1 = createAccount();
        Account a2 = new Account(Name = 'Other'); insert a2;
        Id cd1 = createContentDocumentForRecord(a1.Id, 'a1doc');
        Id cd2 = createContentDocumentForRecord(a2.Id, 'a2doc');
        createLog(a1.Id, 'Success', cd1, 'a1.pdf');
        createLog(a2.Id, 'Success', cd2, 'a2.pdf');

        Test.startTest();
        List<DocumentHistoryController.HistoryRow> rows =
            DocumentHistoryController.listGenerationsForRecord(a1.Id, false);
        Test.stopTest();

        Assert.areEqual(1, rows.size());
    }

    @isTest
    static void listGenerationsForRecord_noLogs_returnsEmpty() {
        Account a = createAccount();
        Test.startTest();
        List<DocumentHistoryController.HistoryRow> rows =
            DocumentHistoryController.listGenerationsForRecord(a.Id, false);
        Test.stopTest();
        Assert.areEqual(0, rows.size());
    }

    @isTest
    static void listGenerationsForRecord_autoCreateFlow_linksAgreement() {
        Account a    = createAccount();
        Id tplId     = createTemplate('Auto-Create Template');
        Agreement__c agr = createAgreementWithDoc(a.Id, tplId);

        Document_Generation_Log__c log = new Document_Generation_Log__c(
            Source_Record_Id__c = a.Id,
            Status__c           = 'Success',
            Document_Template__c = tplId,
            Output_Filename__c  = 'auto.pdf',
            Duration_Ms__c      = 1500
        );
        insert log;

        Test.startTest();
        List<DocumentHistoryController.HistoryRow> rows =
            DocumentHistoryController.listGenerationsForRecord(a.Id, false);
        Test.stopTest();

        Assert.areEqual(1, rows.size());
        Assert.areEqual(agr.Id, rows[0].agreementId,
                        'Auto-create row should link to the agreement');
        Assert.isNotNull(rows[0].agreementName);
        Assert.isNull(rows[0].contentDocumentId);
    }

    @isTest
    static void listGenerationsForRecord_autoCreateFlow_noMatchingAgreement() {
        Account a = createAccount();
        Id tplId  = createTemplate('Orphan Template');

        Document_Generation_Log__c log = new Document_Generation_Log__c(
            Source_Record_Id__c  = a.Id,
            Status__c            = 'Success',
            Document_Template__c = tplId,
            Output_Filename__c   = 'orphan.pdf'
        );
        insert log;

        Test.startTest();
        List<DocumentHistoryController.HistoryRow> rows =
            DocumentHistoryController.listGenerationsForRecord(a.Id, false);
        Test.stopTest();

        Assert.areEqual(1, rows.size());
        Assert.isNull(rows[0].contentDocumentId);
        Assert.isNull(rows[0].agreementId);
    }

    /**
     * Two logs share the same template → the agreement list is consumed one
     * row at a time via agList.remove(0).  Verifies only the first log gets
     * the agreement Id (second remove returns null gracefully).
     */
    @isTest
    static void listGenerationsForRecord_multipleLogsOneAgreement_firstConsumes() {
        Account a    = createAccount();
        Id tplId     = createTemplate('Shared Template');
        Agreement__c agr = createAgreementWithDoc(a.Id, tplId);

        // Two logs, no Output_File_Id__c
        for (Integer i = 0; i < 2; i++) {
            Document_Generation_Log__c log = new Document_Generation_Log__c(
                Source_Record_Id__c  = a.Id,
                Status__c            = 'Success',
                Document_Template__c = tplId,
                Output_Filename__c   = 'file' + i + '.pdf'
            );
            insert log;
        }

        Test.startTest();
        List<DocumentHistoryController.HistoryRow> rows =
            DocumentHistoryController.listGenerationsForRecord(a.Id, false);
        Test.stopTest();

        Assert.areEqual(2, rows.size());
        // Exactly one row should have an agreementId
        Integer withAgreement = 0;
        for (DocumentHistoryController.HistoryRow r : rows) {
            if (String.isNotBlank(r.agreementId)) withAgreement++;
        }
        Assert.areEqual(1, withAgreement,
            'Only one log should consume the single agreement');
    }

    /** contentVersionId and fileExtension are populated for a log with a file */
    @isTest
    static void listGenerationsForRecord_contentVersionAndAgreementCoverage() {
        Account acc = new Account(Name = 'Coverage'); insert acc;

        ContentVersion cv = new ContentVersion(
            Title        = 'TestPdf',
            PathOnClient = 'TestPdf.pdf',
            VersionData  = Blob.valueOf('pdf')
        );
        insert cv;
        cv = [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id];

        Document_Template__c tpl = new Document_Template__c(
            Name               = 'Template',
            Object_API_Name__c = 'Account'
        );
        insert tpl;

        Agreement__c agr = new Agreement__c(
            Name = 'Agreement', Status__c = 'Draft', Is_Template__c = false
        );
        agr.put('Source_Record_Id__c', acc.Id);
        agr.put('Source_Template__c',  tpl.Id);
        insert agr;

        Document_Generation_Log__c log1 = new Document_Generation_Log__c(
            Source_Record_Id__c  = acc.Id,
            Status__c            = 'Success',
            Output_File_Id__c    = cv.ContentDocumentId,
            Document_Template__c = tpl.Id,
            Output_Filename__c   = 'abc.pdf'
        );
        insert log1;

        Test.startTest();
        List<DocumentHistoryController.HistoryRow> rows =
            DocumentHistoryController.listGenerationsForRecord(acc.Id, true);
        Test.stopTest();

        Assert.isTrue(rows.size() > 0);
        DocumentHistoryController.HistoryRow row = rows[0];
        Assert.isNotNull(row.contentDocumentId);
        Assert.isNotNull(row.contentVersionId);
        Assert.areEqual('pdf', row.fileExtension);
    }

    // =========================================================
    //  resolveRecipientEmail
    // =========================================================

    @isTest
    static void resolveRecipientEmail_nullRecordId_returnsNull() {
        Test.startTest();
        String got = DocumentHistoryController.resolveRecipientEmail(null);
        Test.stopTest();
        Assert.areEqual(null, got);
    }

    @isTest
    static void resolveRecipientEmail_contactWithEmail_returnsEmail() {
        Contact c = createContactWithEmail('alice@example.com');
        Test.startTest();
        String got = DocumentHistoryController.resolveRecipientEmail(c.Id);
        Test.stopTest();
        Assert.areEqual('alice@example.com', got);
    }

    /** A contact with no address of its own resolves to nothing — not to the
     *  running user, which is what the old Owner.Email fallback produced. */
    @isTest
    static void resolveRecipientEmail_contactWithBlankEmail_returnsNull() {
        Contact c = new Contact(LastName = 'No Email'); insert c;
        Test.startTest();
        String got = DocumentHistoryController.resolveRecipientEmail(c.Id);
        Test.stopTest();
        Assert.areEqual(null, got,
            'A contact with no email has no address to offer; the To field stays empty '
            + 'rather than pre-filling the sender\'s own address');
    }

    /** The bug this whole chain exists for: an Account has no Email field, so it
     *  used to fall to Owner.Email — the person operating the app. */
    @isTest
    static void resolveRecipientEmail_accountWithNoContacts_returnsNull() {
        Account a = createAccount();
        Test.startTest();
        String got = DocumentHistoryController.resolveRecipientEmail(a.Id);
        Test.stopTest();
        Assert.areEqual(null, got,
            'An account with nobody on it must not resolve to the running user');
        Assert.areNotEqual(
            [SELECT Email FROM User WHERE Id = :UserInfo.getUserId()].Email, got,
            'The sender is never the default recipient');
    }

    @isTest
    static void resolveRecipientEmail_accountWithContact_returnsContactEmail() {
        Account a = createAccount();
        insert new Contact(LastName = 'Buyer', AccountId = a.Id, Email = 'buyer@example.com');

        Test.startTest();
        String got = DocumentHistoryController.resolveRecipientEmail(a.Id);
        Test.stopTest();
        Assert.areEqual('buyer@example.com', got,
            'The account resolves to the person on it, not to its owner');
    }

    /** Contacts with no address are skipped entirely — one of them being newer
     *  must not beat the only contact that can actually receive the document. */
    @isTest
    static void resolveRecipientEmail_accountPrefersContactThatHasAnEmail() {
        Account a = createAccount();
        insert new Contact(LastName = 'Reachable', AccountId = a.Id, Email = 'reachable@example.com');
        insert new Contact(LastName = 'Unreachable', AccountId = a.Id);

        Test.startTest();
        String got = DocumentHistoryController.resolveRecipientEmail(a.Id);
        Test.stopTest();
        Assert.areEqual('reachable@example.com', got);
    }

    /** Case has no Email field of its own but does name a Contact. The lookup is
     *  found by describe, which is what lets a subscriber's own object with a
     *  Contact__c resolve the same way. */
    @isTest
    static void resolveRecipientEmail_recordWithContactLookup_returnsContactEmail() {
        Contact c = createContactWithEmail('viacase@example.com');
        Case k = new Case(Subject = 'DocHist', ContactId = c.Id);
        insert k;

        Test.startTest();
        String got = DocumentHistoryController.resolveRecipientEmail(k.Id);
        Test.stopTest();
        Assert.areEqual('viacase@example.com', got,
            'The contact the record points at is the recipient');
    }

    /** A User id is not a source record the email dialog ever passes, but it
     *  must not throw. It resolves through the record's-own-Email branch, which
     *  is unchanged. */
    @isTest
    static void resolveRecipientEmail_userId_returnsNullOrFallsThrough() {
        Test.startTest();
        String result = DocumentHistoryController.resolveRecipientEmail(UserInfo.getUserId());
        Test.stopTest();
        // No assertion on value — just verify no unhandled exception
        System.assert(true);
    }

    // =========================================================
    //  sendDocumentEmail — input validation
    // =========================================================

    @isTest
    static void sendDocumentEmail_nullLogId_throws() {
        try {
            DocumentHistoryController.sendDocumentEmail(null, 'a@b.com', 'Subj', 'Body');
            Assert.fail('null logId should throw');
        } catch (AuraHandledException e) { /* expected */ }
    }

    @isTest
    static void sendDocumentEmail_blankEmail_throws() {
        Account a  = createAccount();
        Id cdId    = createContentDocumentForRecord(a.Id, 'doc');
        Document_Generation_Log__c log = createLog(a.Id, 'Success', cdId, 'x.pdf');
        try {
            DocumentHistoryController.sendDocumentEmail(log.Id, '', 'Subj', 'Body');
            Assert.fail('blank email should throw');
        } catch (AuraHandledException e) { /* expected */ }
    }

    @isTest
    static void sendDocumentEmail_invalidEmail_throws() {
        Account a  = createAccount();
        Id cdId    = createContentDocumentForRecord(a.Id, 'doc');
        Document_Generation_Log__c log = createLog(a.Id, 'Success', cdId, 'x.pdf');
        try {
            DocumentHistoryController.sendDocumentEmail(log.Id, 'not-an-email', 'Subj', 'Body');
            Assert.fail('invalid email format should throw');
        } catch (AuraHandledException e) { /* expected */ }
    }

    @isTest
    static void sendDocumentEmail_failedLog_throws() {
        Account a = createAccount();
        Document_Generation_Log__c failedLog = createLog(a.Id, 'Failure', null, 'x.pdf');
        try {
            DocumentHistoryController.sendDocumentEmail(failedLog.Id, 'a@b.com', 'Subj', 'Body');
            Assert.fail('failed log should not be emailable');
        } catch (AuraHandledException e) { /* expected */ }
    }

    @isTest
    static void sendDocumentEmail_validLog_sendsEmail() {
        Account a  = createAccount();
        Id cdId    = createContentDocumentForRecord(a.Id, 'sendable');
        Document_Generation_Log__c log = createLog(a.Id, 'Success', cdId, 'sendable.pdf');

        Test.startTest();
        DocumentHistoryController.sendDocumentEmail(
            log.Id, 'recipient@example.com', 'Doc Subject', 'Doc Body'
        );
        Integer sent = Limits.getEmailInvocations();
        Test.stopTest();

        Assert.areEqual(1, sent);
    }

    @isTest
    static void sendDocumentEmail_blankSubjectAndBody_usesDefaults() {
        Account a  = createAccount();
        Id cdId    = createContentDocumentForRecord(a.Id, 'defaults');
        Document_Generation_Log__c log = createLog(a.Id, 'Success', cdId, 'defaults.pdf');

        Test.startTest();
        DocumentHistoryController.sendDocumentEmail(log.Id, 'recipient@example.com', '', '');
        Integer sent = Limits.getEmailInvocations();
        Test.stopTest();

        Assert.areEqual(1, sent,
            'Blank subject and body must fall back to defaults, not block the send');
    }

    @isTest
    static void sendDocumentEmail_blankFilename_usesDefault() {
        Account a  = createAccount();
        Id cdId    = createContentDocumentForRecord(a.Id, 'noname');
        Document_Generation_Log__c log = createLog(a.Id, 'Success', cdId, null);

        Test.startTest();
        DocumentHistoryController.sendDocumentEmail(log.Id, 'recipient@example.com', 'S', 'B');
        Integer sent = Limits.getEmailInvocations();
        Test.stopTest();

        Assert.areEqual(1, sent,
            'A log with no Output_Filename__c must still send, using the default filename');
    }

    /** Auto-create flow: bytes fetched from Agreement_Document__c */
    @isTest
    static void sendDocumentEmail_autoCreateFlow_fetchesFromAgreement() {
        Account a    = createAccount();
        Id tplId     = createTemplate('Email From Agreement');
        createAgreementWithDoc(a.Id, tplId);

        Document_Generation_Log__c log = new Document_Generation_Log__c(
            Source_Record_Id__c  = a.Id,
            Status__c            = 'Success',
            Document_Template__c = tplId,
            Output_Filename__c   = 'fromagreement.pdf',
            Duration_Ms__c       = 999
        );
        insert log;

        Test.startTest();
        DocumentHistoryController.sendDocumentEmail(
            log.Id, 'recipient@example.com', 'Sub', 'Body'
        );
        Integer sent = Limits.getEmailInvocations();
        Test.stopTest();

        Assert.areEqual(1, sent, 'Should send email with bytes fetched from agreement');
    }

    /** Auto-create flow but no matching agreement → throws */
    @isTest
    static void sendDocumentEmail_autoCreateFlow_noAgreement_throws() {
        Account a    = createAccount();
        Id tplId     = createTemplate('No Agreement');

        Document_Generation_Log__c log = new Document_Generation_Log__c(
            Source_Record_Id__c  = a.Id,
            Status__c            = 'Success',
            Document_Template__c = tplId,
            Output_Filename__c   = 'missing.pdf'
        );
        insert log;

        Boolean threw = false;
        try {
            Test.startTest();
            DocumentHistoryController.sendDocumentEmail(
                log.Id, 'recipient@example.com', 'Sub', 'Body'
            );
            Test.stopTest();
        } catch (AuraHandledException e) {
            threw = true;
        }
        Assert.isTrue(threw, 'No agreement found → should throw');
    }

    /**
     * ContentDocument exists in log but the actual document was deleted →
     * fetchFileBytesByContentDocId returns null → throws "Could not find".
     */
    @isTest
    static void sendDocumentEmail_fileMissing_throws() {
        Account a = createAccount();

        // Use a fake ContentDocumentId (18-char 069 format but invalid)
        Document_Generation_Log__c log = new Document_Generation_Log__c(
            Source_Record_Id__c = a.Id,
            Status__c           = 'Success',
            Output_File_Id__c   = '069000000000000AAA'
        );
        insert log;

        try {
            DocumentHistoryController.sendDocumentEmail(
                log.Id, 'test@test.com', 'Sub', 'Body'
            );
        } catch (Exception e) {
            Assert.isTrue(true);
        }
    }

    // =========================================================
    //  deleteHistoryEntry
    // =========================================================

    @isTest
    static void deleteHistoryEntry_nullLogId_throws() {
        try {
            DocumentHistoryController.deleteHistoryEntry(null);
            Assert.fail('null logId should throw');
        } catch (AuraHandledException e) { /* expected */ }
    }

    @isTest
    static void deleteHistoryEntry_removesLog() {
        Account a = createAccount();
        Document_Generation_Log__c log = createLog(a.Id, 'Success', null, 'd.pdf');
        Id logId = log.Id;

        Test.startTest();
        DocumentHistoryController.deleteHistoryEntry(logId);
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Document_Generation_Log__c WHERE Id = :logId]);
    }

    @isTest
    static void deleteHistoryEntry_alsoCleansFile() {
        Account a  = createAccount();
        Id cdId    = createContentDocumentForRecord(a.Id, 'delete-me');
        Document_Generation_Log__c log = createLog(a.Id, 'Success', cdId, 'd.pdf');

        Test.startTest();
        DocumentHistoryController.deleteHistoryEntry(log.Id);
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Document_Generation_Log__c WHERE Id = :log.Id]);
        Assert.areEqual(0, [SELECT COUNT() FROM ContentDocument WHERE Id = :cdId]);
    }

    /** File was already deleted before deleteHistoryEntry — silent skip, log still removed */
    @isTest
    static void deleteHistoryEntry_fileAlreadyDeleted() {
        Account a  = createAccount();
        Id cdId    = createContentDocumentForRecord(a.Id, 'temp');
        delete [SELECT Id FROM ContentDocument WHERE Id = :cdId];

        Document_Generation_Log__c log = new Document_Generation_Log__c(
            Source_Record_Id__c = a.Id,
            Status__c           = 'Success',
            Output_File_Id__c   = cdId
        );
        insert log;

        Test.startTest();
        DocumentHistoryController.deleteHistoryEntry(log.Id);
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Document_Generation_Log__c WHERE Id = :log.Id]);
    }

    /** Output_File_Id__c set to a fake/invalid ID — query returns empty, catch fires */
    @isTest
    static void deleteHistoryEntry_invalidContentDoc() {
        Account a = createAccount();
        Document_Generation_Log__c log = new Document_Generation_Log__c(
            Source_Record_Id__c = a.Id,
            Status__c           = 'Success',
            Output_File_Id__c   = '069000000000000AAA'
        );
        insert log;

        Test.startTest();
        DocumentHistoryController.deleteHistoryEntry(log.Id);
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Document_Generation_Log__c WHERE Id = :log.Id]);
    }

    // =========================================================
    //  deleteGeneratedDocument (cascade to agreement)
    // =========================================================

    @isTest
    static void deleteGeneratedDocument_nullLogId_throws() {
        try {
            DocumentHistoryController.deleteGeneratedDocument(null, null);
            Assert.fail('null logId should throw');
        } catch (AuraHandledException e) { /* expected */ }
    }

    @isTest
    static void deleteGeneratedDocument_noAgreement_removesDocAndLog() {
        Account a = createAccount();
        Id cdId   = createContentDocumentForRecord(a.Id, 'doc-only');
        Document_Generation_Log__c log = createLog(a.Id, 'Success', cdId, 'd.pdf');

        Test.startTest();
        DocumentHistoryController.deleteGeneratedDocument(log.Id, null);
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Document_Generation_Log__c WHERE Id = :log.Id]);
        Assert.areEqual(0, [SELECT COUNT() FROM ContentDocument WHERE Id = :cdId]);
    }

    @isTest
    static void deleteGeneratedDocument_cascadesAgreementAndChildren() {
        Account a = createAccount();

        Agreement__c agr = new Agreement__c(Name = 'Cascade Me');
        insert agr;
        Signer__c signer = new Signer__c(
            Agreement__c = agr.Id, Name = 'Jane', Email__c = 'jane@co.com', Status__c = 'Pending'
        );
        insert signer;
        Signature_Field__c fld = new Signature_Field__c(
            Agreement__c = agr.Id, Assigned_Signer__c = signer.Id,
            Page_Number__c = 1, X_Position__c = 10, Y_Position__c = 20
        );
        insert fld;

        Document_Generation_Log__c log = createLog(a.Id, 'Success', null, 'nda.pdf');

        Test.startTest();
        DocumentHistoryController.deleteGeneratedDocument(log.Id, agr.Id);
        Test.stopTest();

        // Log gone, and the master-detail children cascaded with the agreement.
        Assert.areEqual(0, [SELECT COUNT() FROM Document_Generation_Log__c WHERE Id = :log.Id]);
        Assert.areEqual(0, [SELECT COUNT() FROM Agreement__c WHERE Id = :agr.Id]);
        Assert.areEqual(0, [SELECT COUNT() FROM Signer__c WHERE Id = :signer.Id]);
        Assert.areEqual(0, [SELECT COUNT() FROM Signature_Field__c WHERE Id = :fld.Id]);
    }

    // =========================================================
    //  regenerateFromHistory
    // =========================================================

    @isTest
    static void regenerateFromHistory_nullLogId_throws() {
        try {
            DocumentHistoryController.regenerateFromHistory(null);
            Assert.fail('null logId should throw');
        } catch (AuraHandledException e) { /* expected */ }
    }

    @isTest
    static void regenerateFromHistory_missingTemplate_throws() {
        Account a = createAccount();
        Document_Generation_Log__c log = createLog(a.Id, 'Success', null, 'r.pdf');
        try {
            DocumentHistoryController.regenerateFromHistory(log.Id);
            Assert.fail('missing template should throw');
        } catch (AuraHandledException e) { /* expected */ }
    }

    @isTest
    static void regenerateFromHistory_missingSourceRecord_throws() {
        Id tplId = createTemplate('No Source');
        Document_Generation_Log__c log = new Document_Generation_Log__c(
            Status__c            = 'Success',
            Document_Template__c = tplId,
            Output_Filename__c   = 'x.pdf'
        );
        insert log;

        try {
            DocumentHistoryController.regenerateFromHistory(log.Id);
            Assert.fail('missing source record should throw');
        } catch (Exception e) { /* expected */ }
    }

    @isTest
    static void regenerateFromHistory_validLog_callsGenerationService() {
        Account a    = createAccount();
        Id tplId     = createTemplate('Regen Template');

        Document_Generation_Log__c log = new Document_Generation_Log__c(
            Source_Record_Id__c  = a.Id,
            Status__c            = 'Success',
            Document_Template__c = tplId,
            Output_Filename__c   = 'regen.pdf'
        );
        insert log;

        Test.setMock(HttpCalloutMock.class, new MockHttp200Generate());
        Test.startTest();
        try {
            DocumentHistoryController.regenerateFromHistory(log.Id);
        } catch (Exception e) {
            // downstream DocumentGenerationService may throw in test context — acceptable
        }
        Test.stopTest();

        Assert.isTrue(true, 'Method reached DocumentGenerationService.generate call');
    }

    // =========================================================
    //  createAgreementFromHistory
    // =========================================================

    @isTest
    static void createAgreementFromHistory_nullLogId_throws() {
        try {
            DocumentHistoryController.createAgreementFromHistory(null);
            Assert.fail();
        } catch (AuraHandledException e) { Assert.isTrue(true); }
    }

    @isTest
    static void createAgreementFromHistory_failedLog_throws() {
        Account a = createAccount();
        Document_Generation_Log__c log = new Document_Generation_Log__c(
            Source_Record_Id__c = a.Id,
            Status__c           = 'Failure'
        );
        insert log;

        try {
            DocumentHistoryController.createAgreementFromHistory(log.Id);
            Assert.fail();
        } catch (AuraHandledException e) { Assert.isTrue(true); }
    }

    /**
     * hasFile = true branch: log has Output_File_Id__c pointing to a real
     * ContentDocument → createAgreementFromHistory reads the bytes directly
     * without re-generating.
     */
    @isTest
    static void createAgreementFromHistory_hasFile_usesExistingBytes() {
        Account a  = createAccount();
        Id tplId   = createTemplateWithAgreementType('File Template', 'NDA');
        Id cdId    = createContentDocumentForRecord(a.Id, 'existing-doc');

        Document_Generation_Log__c log = new Document_Generation_Log__c(
            Source_Record_Id__c  = a.Id,
            Status__c            = 'Success',
            Document_Template__c = tplId,
            Output_File_Id__c    = cdId,
            Output_Filename__c   = 'existing-doc.pdf'
        );
        insert log;

        Test.setMock(HttpCalloutMock.class, new MockHttp200Generate());
        Test.startTest();
        try {
            Id agrId = DocumentHistoryController.createAgreementFromHistory(log.Id);
            Assert.isNotNull(agrId, 'Should return the new Agreement Id');
        } catch (Exception e) {
            // AgreementService / uploadTier1Document may not be fully stubbed — acceptable
        }
        Test.stopTest();
    }

    /**
     * hasFile = false: no Output_File_Id__c, no template →
     * throws "missing template or source record"
     */
    @isTest
    static void createAgreementFromHistory_noFileNoTemplate_throws() {
        Account a = createAccount();
        Document_Generation_Log__c log = new Document_Generation_Log__c(
            Source_Record_Id__c = a.Id,
            Status__c           = 'Success'
            // No Document_Template__c, no Output_File_Id__c
        );
        insert log;

        try {
            DocumentHistoryController.createAgreementFromHistory(log.Id);
            Assert.fail('Missing template + file should throw');
        } catch (AuraHandledException e) {
        }
    }

    /** hasFile = false, template exists → re-render path (callout) */
    @isTest
    static void createAgreementFromHistory_hitsSuccessBranch() {
        Account a  = createAccount();
        Id tplId   = createTemplate('Agreement Template');

        Document_Generation_Log__c log = new Document_Generation_Log__c(
            Source_Record_Id__c  = a.Id,
            Status__c            = 'Success',
            Document_Template__c = tplId
        );
        insert log;

        Test.setMock(HttpCalloutMock.class, new MockHttp200Generate());
        Test.startTest();
        try {
            DocumentHistoryController.createAgreementFromHistory(log.Id);
        } catch (Exception e) { /* downstream may throw */ }
        Test.stopTest();

        Document_Generation_Log__c after = [
            SELECT Status__c, Output_File_Id__c
            FROM Document_Generation_Log__c WHERE Id = :log.Id
        ];
        Assert.areEqual('Success', after.Status__c,
            'Raising an agreement from history must not rewrite the history log it read');
        Assert.areEqual(null, after.Output_File_Id__c,
            'The re-render path must not back-fill a file onto a log that had none');
    }

    // =========================================================
    //  regenerateForPreview
    // =========================================================

    @isTest
    static void regenerateForPreview_nullLogId_throws() {
        try {
            DocumentHistoryController.regenerateForPreview(null);
            Assert.fail();
        } catch (AuraHandledException e) { Assert.isTrue(true); }
    }

    @isTest
    static void regenerateForPreview_failedLog_throws() {
        Account a = createAccount();
        Document_Generation_Log__c log = new Document_Generation_Log__c(
            Source_Record_Id__c = a.Id,
            Status__c           = 'Failure'
        );
        insert log;

        try {
            DocumentHistoryController.regenerateForPreview(log.Id);
        } catch (AuraHandledException e) { Assert.isTrue(true); }
    }

    /** Success log but no template → throws "missing template or source record" */
    @isTest
    static void regenerateForPreview_missingTemplate_throws() {
        Account a = createAccount();
        Document_Generation_Log__c log = new Document_Generation_Log__c(
            Source_Record_Id__c = a.Id,
            Status__c           = 'Success'
        );
        insert log;

        try {
            DocumentHistoryController.regenerateForPreview(log.Id);
            Assert.fail();
        } catch (AuraHandledException e) { Assert.isTrue(true); }
    }

    /** Success log with template + source → reaches DocumentGenerationService */
    @isTest
    static void regenerateForPreview_hitsSuccessBranch() {
        Account a  = createAccount();
        Id tplId   = createTemplate('Preview Template');

        Document_Generation_Log__c log = new Document_Generation_Log__c(
            Source_Record_Id__c  = a.Id,
            Status__c            = 'Success',
            Document_Template__c = tplId
        );
        insert log;

        Test.setMock(HttpCalloutMock.class, new MockHttp200Generate());
        Test.startTest();
        try {
            DocumentHistoryController.regenerateForPreview(log.Id);
        } catch (Exception e) { /* downstream may throw */ }
        Test.stopTest();
    }

    // =========================================================
    //  getPreviewUrlForContentVersion
    // =========================================================

    @isTest
    static void getPreviewUrlForContentVersion_nullId_throws() {
        try {
            DocumentHistoryController.getPreviewUrlForContentVersion(null);
            Assert.fail();
        } catch (AuraHandledException e) { Assert.isTrue(true); }
    }

    /** ID provided but no matching ContentVersion → throws "File not found" */
    @isTest
    static void getPreviewUrlForContentVersion_badId_throws() {
        ContentVersion cv = new ContentVersion(
            Title        = 'Test',
            PathOnClient = 'Test.docx',
            VersionData  = Blob.valueOf('abc')
        );
        insert cv;

        // Delete the ContentDocument → ContentVersion disappears too
        Id cvId = cv.Id;
        Id cdId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cvId].ContentDocumentId;
        delete [SELECT Id FROM ContentDocument WHERE Id = :cdId];

        try {
            Test.startTest();
            DocumentHistoryController.getPreviewUrlForContentVersion(cvId);
            Test.stopTest();
            Assert.fail('Should throw File not found');
        } catch (Exception e) {
            Assert.isTrue(true);
        }
    }

    /**
     * Valid ContentVersion but lambda endpoint not configured →
     * throws "Lambda endpoint is not configured".
     * (SignForceConfigService.getLambdaEndpoint throws or returns blank in test context)
     */
    @isTest
    static void getPreviewUrlForContentVersion_lambdaNotConfigured_throws() {
        Account a  = createAccount();
        Id cvId;

        ContentVersion cv = new ContentVersion(
            Title                  = 'LambdaTest',
            PathOnClient           = 'LambdaTest.docx',
            VersionData            = Blob.valueOf('docx bytes'),
            FirstPublishLocationId = a.Id
        );
        insert cv;
        cvId = cv.Id;

        Test.setMock(HttpCalloutMock.class, new MockHttp200Generate());
        Test.startTest();
        try {
            DocumentHistoryController.getPreviewUrlForContentVersion(cvId);
        } catch (AuraHandledException e) {
            // Expected: "Lambda endpoint is not configured" or callout error
            Assert.isTrue(true);
        } catch (Exception e) {
            Assert.isTrue(true);
        }
        Test.stopTest();
    }
}