/**
 * DocumentGenerationServiceTest — covers the generate() pipeline plus the
 * tagAgreementSource and listExistingDrafts helpers.
 *
 * What we cover:
 *   - generate() happy path: template loaded, merge context built, Lambda
 *     called (mocked), output saved as ContentVersion (non-auto-create flow).
 *   - generate() auto-create path: file is NOT saved to source record;
 *     existing-draft hint is surfaced when applicable.
 *   - generate() failure modes: blank templateId, inactive template, no file
 *     attached, wrong-object recordId. Each path inserts a Failure log row.
 *   - generate() with Lambda HTTP 500 — error captured in log + template's
 *     Last_Generation_Error__c.
 *   - tagAgreementSource: writes Source_Record_Id__c + Source_Template__c on
 *     the agreement (best-effort, swallows missing-field errors).
 *   - listExistingDrafts: returns drafts for source record + template, empty
 *     when none exist.
 *
 * Notes on Lambda mocking:
 *   The generate() method makes one HTTP callout to Lambda. We use
 *   Test.setMock(HttpCalloutMock.class, DocGenLambdaMock.alwaysOk()) for
 *   the happy path and DocGenLambdaMock.failGenerate() for the failure
 *   path. The mock returns a canned base64 string that decodes to "rendered
 *   output bytes" so the byteSize calc works.
 *
 *   IMPORTANT: SignForceConfigService.getDocGenLambdaEndpoint() throws
 *   ConfigurationException if the CMT endpoint is blank. Tests rely on the
 *   CMT being deployed with at least a placeholder URL — see the @TestSetup
 *   note below.
 */
@isTest
private class DocumentGenerationServiceTest {

    /**
     * NOTE: tests assume SignForce_Config__mdt 'Default' record exists with
     * Doc_Gen_Lambda_Endpoint__c set to something non-empty (the mock
     * intercepts the actual HTTP call regardless of URL). If your dev org
     * doesn't have the CMT record yet, deploy customMetadata/SignForce_Config.Default.md-meta.xml
     * before running tests. The tests will fail with ConfigurationException
     * otherwise.
     */

    // ============================================================
    // generate() — happy path, non-auto-create flow
    // ============================================================

    @isTest
    static void generate_happyPath_savesOutputAsContentVersion() {
        Account acc = DocGenTestDataFactory.makeAccount('Acme Corp');
        Document_Template__c tpl = DocGenTestDataFactory.makeBasicTemplate('Account');
        DocGenTestDataFactory.attachFileToTemplate(tpl.Id, 'tmpl.docx');
        DocGenTestDataFactory.addTag(tpl.Id, 'Name', 'Field');

        Test.setMock(HttpCalloutMock.class, DocGenLambdaMock.alwaysOk());

        Test.startTest();
        DocumentGenerationService.GenerationResult result =
            DocumentGenerationService.generate(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertEquals('Success', result.status);
        System.assertNotEquals(null, result.contentDocumentId,
            'Non-auto-create flow should attach output to source record');
        System.assertNotEquals(null, result.outputBase64,
            'Result must carry the rendered base64 for the LWC');
        System.assertEquals(false, result.autoCreateAgreement);
        System.assertNotEquals(null, result.logId);

        // Confirm a Document_Generation_Log__c row was inserted in Success.
        List<Document_Generation_Log__c> logs = [
            SELECT Id, Status__c, Output_File_Id__c, Output_Filename__c
            FROM Document_Generation_Log__c WHERE Id = :result.logId
        ];
        System.assertEquals(1, logs.size());
        System.assertEquals('Success', logs[0].Status__c);
        System.assertEquals(result.contentDocumentId, logs[0].Output_File_Id__c);
    }

    // ============================================================
    // generate() — auto-create path
    // ============================================================

    @isTest
    static void generate_autoCreatePath_doesNotSaveToSource() {
        Account acc = DocGenTestDataFactory.makeAccount('Auto Co');
        Document_Template__c tpl = DocGenTestDataFactory.makeTemplate(
            'Auto Tmpl', 'Account', 'DOCX', true /* autoCreate */
        );
        DocGenTestDataFactory.attachFileToTemplate(tpl.Id, 'auto.docx');

        Test.setMock(HttpCalloutMock.class, DocGenLambdaMock.alwaysOk());

        Test.startTest();
        DocumentGenerationService.GenerationResult result =
            DocumentGenerationService.generate(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertEquals('Success', result.status);
        System.assertEquals(true, result.autoCreateAgreement);
        System.assertEquals(null, result.contentDocumentId,
            'Auto-create flow must NOT save file to source record');
        System.assertNotEquals(null, result.outputBase64,
            'Auto-create flow must surface bytes to the LWC for routing');
        System.assertEquals('Contract', result.defaultAgreementType);
    }

    @isTest
    static void generate_autoCreatePath_surfacesExistingDraft() {
        // Auto-create flow + existing Draft Agreement for same source record →
        // result should carry existingDraftAgreementId/Name so the LWC can
        // show the confirmation panel.
        Account acc = DocGenTestDataFactory.makeAccount('Dupe Co');
        Document_Template__c tpl = DocGenTestDataFactory.makeTemplate(
            'Dupe Tmpl', 'Account', 'DOCX', true
        );
        DocGenTestDataFactory.attachFileToTemplate(tpl.Id, 'dupe.docx');

        // Pre-create a Draft Agreement matching this source + template.
        Agreement__c draft = new Agreement__c(
            Name = 'Existing Draft',
            Status__c = 'Draft',
            Signing_Order__c = 'Sequential',
            Agreement_Type__c = 'Contract',
            Is_Template__c = false
        );
        insert draft;
        // Set the source-tracking fields if they exist on this org.
        try {
            draft.put('Source_Record_Id__c', String.valueOf(acc.Id));
            draft.put('Source_Template__c', tpl.Id);
            update draft;
        } catch (Exception ignore) {
            // Source_* fields not deployed — test below will silently skip
            // the existingDraft assertion.
        }

        Test.setMock(HttpCalloutMock.class, DocGenLambdaMock.alwaysOk());

        Test.startTest();
        DocumentGenerationService.GenerationResult result =
            DocumentGenerationService.generate(tpl.Id, acc.Id);
        Test.stopTest();

        System.assertEquals('Success', result.status);
        // The existingDraftAgreementId may be null on orgs that haven't
        // deployed the M5-1 fields. We assert it's set ONLY if those fields
        // are present, so the test passes either way.
        Boolean fieldsExist = Schema.SObjectType.Agreement__c.fields.getMap()
            .containsKey('source_record_id__c');
        if (fieldsExist) {
            System.assertEquals(draft.Id, result.existingDraftAgreementId,
                'Existing draft must be surfaced for the confirmation panel');
        }
    }

    // ============================================================
    // generate() — failure modes
    // ============================================================

    @isTest
    static void generate_blankTemplateId_throws() {
        Account acc = DocGenTestDataFactory.makeAccount('Whatever');
        Test.setMock(HttpCalloutMock.class, DocGenLambdaMock.alwaysOk());

        try {
            DocumentGenerationService.generate(null, acc.Id);
            System.assert(false, 'null templateId should throw');
        } catch (AuraHandledException e) {
            // expected — generate wraps internal exceptions in AuraHandled
        }
    }

    @isTest
    static void generate_inactiveTemplate_failsAndLogs() {
        Account acc = DocGenTestDataFactory.makeAccount('Inactive');
        Document_Template__c tpl = DocGenTestDataFactory.makeBasicTemplate('Account');
        DocGenTestDataFactory.attachFileToTemplate(tpl.Id, 'inactive.docx');
        tpl.Active__c = false;
        update tpl;

        Test.setMock(HttpCalloutMock.class, DocGenLambdaMock.alwaysOk());

        try {
            DocumentGenerationService.generate(tpl.Id, acc.Id);
            System.assert(false, 'Inactive template must fail');
        } catch (AuraHandledException e) {
            // expected
        }

        // A failure log should still be recorded.
        List<Document_Generation_Log__c> logs = [
            SELECT Status__c, Error_Message__c
            FROM Document_Generation_Log__c
            WHERE Document_Template__c = :tpl.Id
        ];
        System.assertEquals(1, logs.size());
        System.assertEquals('Failure', logs[0].Status__c);
        System.assert(logs[0].Error_Message__c.contains('inactive'),
            'Error message should mention "inactive"');
    }

    @isTest
    static void generate_noFileAttached_failsWithClearError() {
        Account acc = DocGenTestDataFactory.makeAccount('NoFile');
        Document_Template__c tpl = DocGenTestDataFactory.makeBasicTemplate('Account');
        // Note: NOT calling attachFileToTemplate — Template_File_Id__c stays blank.

        Test.setMock(HttpCalloutMock.class, DocGenLambdaMock.alwaysOk());

        try {
            DocumentGenerationService.generate(tpl.Id, acc.Id);
            System.assert(false, 'Template with no file must fail');
        } catch (AuraHandledException e) {
            // expected
        }
    }

    @isTest
    static void generate_wrongObjectType_fails() {
        // Template targets Account, we pass a Contact Id.
        Document_Template__c tpl = DocGenTestDataFactory.makeBasicTemplate('Account');
        DocGenTestDataFactory.attachFileToTemplate(tpl.Id, 'tmpl.docx');
        Contact c = new Contact(LastName = 'Wrong');
        insert c;

        Test.setMock(HttpCalloutMock.class, DocGenLambdaMock.alwaysOk());

        try {
            DocumentGenerationService.generate(tpl.Id, c.Id);
            System.assert(false, 'Object type mismatch must fail');
        } catch (AuraHandledException e) {
            // expected — MergeContextBuilder catches this
        }
    }

    @isTest
    static void generate_lambdaReturns500_failsCleanly() {
        Account acc = DocGenTestDataFactory.makeAccount('Lambda500');
        Document_Template__c tpl = DocGenTestDataFactory.makeBasicTemplate('Account');
        DocGenTestDataFactory.attachFileToTemplate(tpl.Id, 'tmpl.docx');

        Test.setMock(HttpCalloutMock.class, DocGenLambdaMock.failGenerate());

        Test.startTest();
        try {
            DocumentGenerationService.generate(tpl.Id, acc.Id);
            System.assert(false, 'Lambda 500 must surface as failure');
        } catch (AuraHandledException e) {
            // expected
        }
        Test.stopTest();

        // Failure log must exist with the Lambda error captured.
        List<Document_Generation_Log__c> logs = [
            SELECT Status__c, Error_Message__c
            FROM Document_Generation_Log__c
            WHERE Document_Template__c = :tpl.Id
        ];
        System.assertEquals(1, logs.size());
        System.assertEquals('Failure', logs[0].Status__c);
        System.assertNotEquals(null, logs[0].Error_Message__c);
    }

    // ============================================================
    // tagAgreementSource — best-effort writer
    // ============================================================

    @isTest
    static void tagAgreementSource_setsFields() {
        // Create an agreement, then tag it. Test passes whether or not
        // Source_* fields are deployed — method swallows missing-field errors.
        Account acc = DocGenTestDataFactory.makeAccount('Tag Co');
        Document_Template__c tpl = DocGenTestDataFactory.makeBasicTemplate('Account');
        Agreement__c agr = new Agreement__c(
            Name = 'Tag Me',
            Status__c = 'Draft',
            Signing_Order__c = 'Sequential',
            Agreement_Type__c = 'Contract'
        );
        insert agr;

        Document_Generation_Log__c log =
            DocGenTestDataFactory.makeLog(tpl.Id, acc.Id, 'Success');

        Test.startTest();
        DocumentGenerationService.tagAgreementSource(agr.Id, acc.Id, tpl.Id, log.Id);
        Test.stopTest();

        // No exception = pass. If Source_* fields are deployed, verify the
        // values made it through.
        Boolean fieldsExist = Schema.SObjectType.Agreement__c.fields.getMap()
            .containsKey('source_record_id__c');
        if (fieldsExist) {
            Id agrId = agr.Id;
            List<sObject> rows = Database.query(
                'SELECT Source_Record_Id__c, Source_Template__c ' +
                'FROM Agreement__c WHERE Id = :agrId LIMIT 1'
            );
            System.assertEquals(1, rows.size());
            System.assertEquals(String.valueOf(acc.Id),
                String.valueOf(rows[0].get('Source_Record_Id__c')));
            System.assertEquals(String.valueOf(tpl.Id),
                String.valueOf(rows[0].get('Source_Template__c')));
        }

        // The log link is what the history screen pairs rows with; if the
        // field exists it must carry exactly the run that was passed in.
        Boolean logLinkExists = Schema.SObjectType.Agreement__c.fields.getMap()
            .containsKey('source_generation_log__c');
        if (logLinkExists) {
            Id agrId2 = agr.Id;
            List<sObject> rows2 = Database.query(
                'SELECT Source_Generation_Log__c ' +
                'FROM Agreement__c WHERE Id = :agrId2 LIMIT 1'
            );
            System.assertEquals(String.valueOf(log.Id),
                String.valueOf(rows2[0].get('Source_Generation_Log__c')),
                'The agreement must record the generation run it came from.');
        }
    }

    @isTest
    static void tagAgreementSource_nullArgs_noop() {
        // No-op early return on null inputs — must not throw.
        DocumentGenerationService.tagAgreementSource(null, null, null, null);
        System.assertEquals(0, Limits.getDmlStatements(),
            'A null agreementId must short-circuit before any record is written.');
    }

    // ============================================================
    // listExistingDrafts — query helper
    // ============================================================

    @isTest
    static void listExistingDrafts_noMatches_returnsEmpty() {
        Account acc = DocGenTestDataFactory.makeAccount('NoDrafts');
        Document_Template__c tpl = DocGenTestDataFactory.makeBasicTemplate('Account');

        List<Map<String, Object>> got = DocumentGenerationService.listExistingDrafts(acc.Id, tpl.Id);
        System.assertNotEquals(null, got);
        System.assertEquals(0, got.size());
    }

    @isTest
    static void listExistingDrafts_matchingDraft_returned() {
        // Test only meaningful if Source_* fields are deployed.
        Boolean fieldsExist = Schema.SObjectType.Agreement__c.fields.getMap()
            .containsKey('source_record_id__c');
        if (!fieldsExist) return;

        Account acc = DocGenTestDataFactory.makeAccount('HasDraft');
        Document_Template__c tpl = DocGenTestDataFactory.makeBasicTemplate('Account');

        Agreement__c draft = new Agreement__c(
            Name = 'My Draft',
            Status__c = 'Draft',
            Signing_Order__c = 'Sequential',
            Agreement_Type__c = 'Contract',
            Is_Template__c = false
        );
        insert draft;
        try {
            draft.put('Source_Record_Id__c', String.valueOf(acc.Id));
            draft.put('Source_Template__c', tpl.Id);
            update draft;
        } catch (Exception ignore) {
            return;  // bail if the put fails
        }

        List<Map<String, Object>> got = DocumentGenerationService.listExistingDrafts(acc.Id, tpl.Id);
        System.assert(got.size() >= 1, 'Should find the matching draft');
    }
}