@isTest
private class TemplateServiceTest {

    // ─── Mock HTTP Callout ─────────────────────────────────────────────────────

    private class MockLambdaSuccess implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody(JSON.serialize(new Map<String, Object>{
                'tags' => new List<Object>{
                    new Map<String, Object>{ 'name' => 'FirstName',  'type' => 'Field',  'blockId' => null },
                    new Map<String, Object>{ 'name' => 'LastName',   'type' => 'Field',  'blockId' => null },
                    new Map<String, Object>{ 'name' => 'Items',      'type' => 'Loop',   'blockId' => null },
                    new Map<String, Object>{ 'name' => 'ItemName',   'type' => 'Field',  'blockId' => 'Items' },
                    new Map<String, Object>{ 'name' => 'Amount',     'type' => 'Field',  'blockId' => 'Items' }
                }
            }));
            return res;
        }
    }

    private class MockLambdaFailure implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(500);
            res.setBody('Internal Server Error');
            return res;
        }
    }

    private class MockLambdaPreviewSuccess implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody(JSON.serialize(new Map<String, Object>{
                'success' => true,
                'url'     => 'https://s3.amazonaws.com/preview/test.pdf'
            }));
            return res;
        }
    }

    private class MockLambdaPreviewNoUrl implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody(JSON.serialize(new Map<String, Object>{
                'success' => false,
                'error'   => 'Conversion failed'
            }));
            return res;
        }
    }

    private class MockLambdaEmptyTags implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody(JSON.serialize(new Map<String, Object>{
                'tags' => new List<Object>()
            }));
            return res;
        }
    }

    // ─── Test Data Helpers ─────────────────────────────────────────────────────

    private static Document_Template__c createTemplate(String name, String objectApiName) {
        Document_Template__c tpl = new Document_Template__c();
        tpl.Name               = name;
        tpl.Object_API_Name__c = objectApiName;
        tpl.Output_Format__c   = 'DOCX';
        tpl.Active__c          = true;
        insert tpl;
        return tpl;
    }

    private static ContentVersion createContentVersion(String title) {
        ContentVersion cv = new ContentVersion();
        cv.Title         = title;
        cv.PathOnClient  = title + '.docx';
        cv.VersionData   = Blob.valueOf('Mock DOCX content for testing purposes');
        cv.IsMajorVersion = true;
        insert cv;
        return [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id];
    }

    // ─── getEligibleObjects Tests ──────────────────────────────────────────────

    @isTest
    static void testGetEligibleObjects_ReturnsNonEmptyList() {
        Test.startTest();
        List<Map<String, String>> result = TemplateService.getEligibleObjects();
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assert(result.size() > 0, 'Should return at least one eligible object');
    }

    @isTest
    static void testGetEligibleObjects_ContainsRequiredKeys() {
        Test.startTest();
        List<Map<String, String>> result = TemplateService.getEligibleObjects();
        Test.stopTest();

        System.assert(result.size() > 0, 'Should have at least one result');
        Map<String, String> first = result[0];
        System.assert(first.containsKey('value'),   'Each entry must have value key');
        System.assert(first.containsKey('label'),   'Each entry must have label key');
        System.assert(first.containsKey('isCustom'),'Each entry must have isCustom key');
    }

    @isTest
    static void testGetEligibleObjects_IsSortedByLabel() {
        Test.startTest();
        List<Map<String, String>> result = TemplateService.getEligibleObjects();
        Test.stopTest();

        for (Integer i = 1; i < result.size(); i++) {
            String prev = result[i - 1].get('label');
            String curr = result[i].get('label');
            System.assert(prev.compareTo(curr) <= 0,
                'Results should be sorted alphabetically by label');
        }
    }

    @isTest
    static void testGetEligibleObjects_ExcludesSetupObjects() {
        Test.startTest();
        List<Map<String, String>> result = TemplateService.getEligibleObjects();
        Test.stopTest();

        for (Map<String, String> obj : result) {
            String val = obj.get('value');
            System.assert(!val.startsWith('Apex'),
                'Should exclude Apex setup objects: ' + val);
            System.assert(!val.startsWith('Permission'),
                'Should exclude Permission objects: ' + val);
            System.assert(!val.endsWith('Share'),
                'Should exclude Share objects: ' + val);
            System.assert(!val.endsWith('History'),
                'Should exclude History objects: ' + val);
            System.assert(!val.endsWith('Feed'),
                'Should exclude Feed objects: ' + val);
            System.assert(!val.endsWith('ChangeEvent'),
                'Should exclude ChangeEvent objects: ' + val);
        }
    }

    @isTest
    static void testGetEligibleObjects_ContainsAccountAndContact() {
        Test.startTest();
        List<Map<String, String>> result = TemplateService.getEligibleObjects();
        Test.stopTest();

        Set<String> values = new Set<String>();
        for (Map<String, String> obj : result) {
            values.add(obj.get('value'));
        }
        System.assert(values.contains('Account'), 'Account should be in eligible objects');
        System.assert(values.contains('Contact'), 'Contact should be in eligible objects');
    }

    // ─── getObjectFieldTree Tests ──────────────────────────────────────────────

    @isTest
    static void testGetObjectFieldTree_ReturnsValidStructure() {
        Test.startTest();
        Map<String, Object> result = TemplateService.getObjectFieldTree('Account');
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assertEquals('Account', result.get('objectApiName'), 'objectApiName should match');
        System.assertNotEquals(null, result.get('objectLabel'),       'objectLabel should be present');
        System.assertNotEquals(null, result.get('fields'),            'fields should be present');
        System.assertNotEquals(null, result.get('relationships'),     'relationships should be present');
        System.assertNotEquals(null, result.get('childCollections'),  'childCollections should be present');
        System.assertNotEquals(null, result.get('builtins'),          'builtins should be present');
    }

    @isTest
    static void testGetObjectFieldTree_FieldsHaveRequiredKeys() {
        Test.startTest();
        Map<String, Object> result = TemplateService.getObjectFieldTree('Account');
        Test.stopTest();

        List<Object> fields = (List<Object>) result.get('fields');
        System.assert(fields.size() > 0, 'Account should have accessible fields');

        Map<String, Object> firstField = (Map<String, Object>) fields[0];
        System.assert(firstField.containsKey('name'),  'Field must have name');
        System.assert(firstField.containsKey('label'), 'Field must have label');
        System.assert(firstField.containsKey('type'),  'Field must have type');
        System.assert(firstField.containsKey('tag'),   'Field must have tag');
    }

    @isTest
    static void testGetObjectFieldTree_BuiltinsContainExpectedTags() {
        Test.startTest();
        Map<String, Object> result = TemplateService.getObjectFieldTree('Account');
        Test.stopTest();

        List<Object> builtins = (List<Object>) result.get('builtins');
        System.assertEquals(7, builtins.size(), 'Should have 7 built-in tags');

        Set<String> builtinNames = new Set<String>();
        for (Object b : builtins) {
            Map<String, Object> bMap = (Map<String, Object>) b;
            builtinNames.add((String) bMap.get('name'));
        }
        System.assert(builtinNames.contains('TODAY'),         'Should have TODAY builtin');
        System.assert(builtinNames.contains('NOW'),           'Should have NOW builtin');
        System.assert(builtinNames.contains('USER.FullName'), 'Should have USER.FullName builtin');
        System.assert(builtinNames.contains('ORG.Name'),      'Should have ORG.Name builtin');
    }

    @isTest
    static void testGetObjectFieldTree_ThrowsForBlankObjectName() {
        Boolean exceptionThrown = false;
        try {
            Test.startTest();
            TemplateService.getObjectFieldTree('');
            Test.stopTest();
        } catch (AuraHandledException e) {
            exceptionThrown = true;
        }
        System.assertEquals(true, exceptionThrown, 'Should throw for blank object name');
    }

    @isTest
    static void testGetObjectFieldTree_ThrowsForUnknownObject() {
        Boolean exceptionThrown = false;
        try {
            Test.startTest();
            TemplateService.getObjectFieldTree('NonExistent__Fake__c');
            Test.stopTest();
        } catch (AuraHandledException e) {
            exceptionThrown = true;
        }
        System.assertEquals(true, exceptionThrown, 'Should throw for unknown object');
    }

    @isTest
    static void testGetObjectFieldTree_TagFormatsForSpecialTypes() {
        Test.startTest();
        Map<String, Object> result = TemplateService.getObjectFieldTree('Opportunity');
        Test.stopTest();

        List<Object> fields = (List<Object>) result.get('fields');
        Boolean foundFormattedTag = false;

        for (Object f : fields) {
            Map<String, Object> fMap = (Map<String, Object>) f;
            String tag = (String) fMap.get('tag');
            // Currency/Date/Percent fields should have format modifiers
            if (tag != null && tag.contains(':format=')) {
                foundFormattedTag = true;
                break;
            }
        }
        System.assert(foundFormattedTag,
            'Opportunity should have at least one field with a format modifier tag (e.g. Amount, CloseDate)');
    }

    // ─── registerTemplate Tests ────────────────────────────────────────────────

    @isTest
    static void testRegisterTemplate_CreatesNewTemplate() {
        Test.startTest();
        Id tplId = TemplateService.registerTemplate(
            null, 'My Template', 'Account', null,
            'DOCX', '{{Name}}_doc', true, false, null, 'A test template'
        );
        Test.stopTest();

        System.assertNotEquals(null, tplId, 'Should return a template Id');
        Document_Template__c tpl = [
            SELECT Name, Object_API_Name__c, Active__c, Output_Format__c
            FROM Document_Template__c WHERE Id = :tplId
        ];
        System.assertEquals('My Template', tpl.Name);
        System.assertEquals('Account',     tpl.Object_API_Name__c);
        System.assertEquals(true,          tpl.Active__c);
        System.assertEquals('DOCX',        tpl.Output_Format__c);
    }

    @isTest
    static void testRegisterTemplate_UpdatesExistingTemplate() {
        Document_Template__c existing = createTemplate('Old Name', 'Contact');

        Test.startTest();
        Id tplId = TemplateService.registerTemplate(
            existing.Id, 'Updated Name', 'Contact', null,
            'DOCX', null, true, false, null, null
        );
        Test.stopTest();

        Document_Template__c updated = [
            SELECT Name FROM Document_Template__c WHERE Id = :tplId
        ];
        System.assertEquals('Updated Name', updated.Name, 'Name should be updated');
    }

    @isTest
    static void testRegisterTemplate_DefaultsToDocxWhenFormatBlank() {
        Test.startTest();
        Id tplId = TemplateService.registerTemplate(
            null, 'Format Test', 'Account', null,
            '', null, true, false, null, null
        );
        Test.stopTest();

        Document_Template__c tpl = [
            SELECT Output_Format__c FROM Document_Template__c WHERE Id = :tplId
        ];
        System.assertEquals('DOCX', tpl.Output_Format__c,
            'Should default to DOCX when format is blank');
    }

    @isTest
    static void testRegisterTemplate_ThrowsWhenNameBlank() {
        Boolean exceptionThrown = false;
        try {
            Test.startTest();
            TemplateService.registerTemplate(
                null, '', 'Account', null, 'DOCX', null, true, false, null, null
            );
            Test.stopTest();
        } catch (AuraHandledException e) {
            exceptionThrown = true;
        }
        System.assertEquals(true, exceptionThrown, 'Should throw when name is blank');
    }

    @isTest
    static void testRegisterTemplate_ThrowsWhenObjectApiNameBlank() {
        Boolean exceptionThrown = false;
        try {
            Test.startTest();
            TemplateService.registerTemplate(
                null, 'Some Template', '', null, 'DOCX', null, true, false, null, null
            );
            Test.stopTest();
        } catch (AuraHandledException e) {
            exceptionThrown = true;
        }
        System.assertEquals(true, exceptionThrown, 'Should throw when object API name is blank');
    }

    @isTest
    static void testRegisterTemplate_SetsAutoCreateAgreement() {
        Test.startTest();
        Id tplId = TemplateService.registerTemplate(
            null, 'AutoCreate Template', 'Opportunity', null,
            'DOCX', null, true, true, 'Standard', null
        );
        Test.stopTest();

        Document_Template__c tpl = [
            SELECT Auto_Create_Agreement__c, Default_Agreement_Type__c
            FROM Document_Template__c WHERE Id = :tplId
        ];
        System.assertEquals(true,       tpl.Auto_Create_Agreement__c);
        System.assertEquals('Standard', tpl.Default_Agreement_Type__c);
    }

    // ─── getContentVersionId Tests ─────────────────────────────────────────────

    @isTest
    static void testGetContentVersionId_ReturnsVersionId() {
        ContentVersion cv = createContentVersion('TestDoc');

        Test.startTest();
        Id result = TemplateService.getContentVersionId(cv.ContentDocumentId);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Should return a ContentVersion Id');
    }

    @isTest
    static void testGetContentVersionId_ThrowsForInvalidDocumentId() {
        Boolean exceptionThrown = false;
        // Create a valid-format fake ContentDocumentId won't work directly,
        // so use a real insert then delete to get a stale id
        ContentVersion cv = createContentVersion('DeleteDoc');
        Id docId = cv.ContentDocumentId;
        delete [SELECT Id FROM ContentDocument WHERE Id = :docId];

        try {
            Test.startTest();
            TemplateService.getContentVersionId(docId);
            Test.stopTest();
        } catch (AuraHandledException e) {
            exceptionThrown = true;
        }
        System.assertEquals(true, exceptionThrown, 'Should throw for missing document');
    }

    // ─── parseAndSaveTags Tests ────────────────────────────────────────────────

    @isTest
    static void testParseAndSaveTags_SavesTagsSuccessfully() {
        Document_Template__c tpl = createTemplate('Parse Test', 'Account');
        ContentVersion cv = createContentVersion('ParseTestDoc');

        tpl.Template_File_Id__c = cv.Id;
        update tpl;

        Test.setMock(HttpCalloutMock.class, new MockLambdaSuccess());

        Test.startTest();
        TemplateService.parseAndSaveTags(tpl.Id, cv.Id);
        Test.stopTest();

        List<Document_Template_Field__c> fields = [
            SELECT Id, Tag_Name__c, Field_Type__c, Loop_Parent__c
            FROM Document_Template_Field__c
            WHERE Document_Template__c = :tpl.Id
        ];
        System.assertEquals(5, fields.size(), 'Should save 5 tags from mock response');

        // Verify loop parent linkage
        Boolean foundChildWithParent = false;
        for (Document_Template_Field__c f : fields) {
            if (f.Loop_Parent__c != null) {
                foundChildWithParent = true;
            }
        }
        System.assert(foundChildWithParent, 'Loop child fields should have Loop_Parent__c set');
    }

    @isTest
    static void testParseAndSaveTags_RollsBackOnLambdaFailure() {
        Document_Template__c tpl = createTemplate('Rollback Test', 'Account');
        ContentVersion cv = createContentVersion('RollbackDoc');

        tpl.Template_File_Id__c = cv.Id;
        update tpl;

        // Pre-insert some existing fields that should NOT be deleted on failure
        Document_Template_Field__c existingField = new Document_Template_Field__c();
        existingField.Document_Template__c = tpl.Id;
        existingField.Tag_Name__c          = 'ExistingField';
        existingField.Field_Type__c        = 'Field';
        insert existingField;

        Test.setMock(HttpCalloutMock.class, new MockLambdaFailure());

        Boolean exceptionThrown = false;
        try {
            Test.startTest();
            TemplateService.parseAndSaveTags(tpl.Id, cv.Id);
            Test.stopTest();
        } catch (Exception e) {
            exceptionThrown = true;
        }

        System.assertEquals(true, exceptionThrown, 'Should throw on lambda failure');

        // Existing fields should be rolled back (restored)
        Integer fieldCount = [
            SELECT COUNT() FROM Document_Template_Field__c
            WHERE Document_Template__c = :tpl.Id
        ];
        System.assertEquals(1, fieldCount,
            'Savepoint rollback should restore pre-existing fields');
    }

    @isTest
    static void testParseAndSaveTags_HandlesEmptyTagList() {
        Document_Template__c tpl = createTemplate('Empty Tags Test', 'Account');
        ContentVersion cv = createContentVersion('EmptyTagsDoc');

        tpl.Template_File_Id__c = cv.Id;
        update tpl;

        Test.setMock(HttpCalloutMock.class, new MockLambdaEmptyTags());

        Test.startTest();
        TemplateService.parseAndSaveTags(tpl.Id, cv.Id);
        Test.stopTest();

        Integer fieldCount = [
            SELECT COUNT() FROM Document_Template_Field__c
            WHERE Document_Template__c = :tpl.Id
        ];
        System.assertEquals(0, fieldCount, 'No fields should be saved for empty tag list');

        Document_Template__c updated = [
            SELECT Last_Parsed_Date__c, Last_Parse_Error__c
            FROM Document_Template__c WHERE Id = :tpl.Id
        ];
        System.assertNotEquals(null, updated.Last_Parsed_Date__c,
            'Last_Parsed_Date__c should be set even for empty tags');
        // BUG-033 — an empty tag list must surface an actionable parse error
        // instead of silently recording a successful parse with 0 fields.
        System.assertNotEquals(null, updated.Last_Parse_Error__c,
            'Last_Parse_Error__c should be set when 0 merge tags are detected');
        System.assert(updated.Last_Parse_Error__c.contains('0 merge tags'),
            'Parse error should explain that 0 merge tags were detected');
    }

    @isTest
    static void testParseAndSaveTags_ClearsErrorOnSuccess() {
        Document_Template__c tpl = createTemplate('Clear Error Test', 'Account');
        ContentVersion cv = createContentVersion('ClearErrorDoc');

        // Seed a stale parse error that a successful parse should clear.
        tpl.Template_File_Id__c = cv.Id;
        tpl.Last_Parse_Error__c = 'Stale error from a previous failed parse';
        update tpl;

        Test.setMock(HttpCalloutMock.class, new MockLambdaSuccess());

        Test.startTest();
        TemplateService.parseAndSaveTags(tpl.Id, cv.Id);
        Test.stopTest();

        Document_Template__c updated = [
            SELECT Last_Parse_Error__c FROM Document_Template__c WHERE Id = :tpl.Id
        ];
        System.assertEquals(null, updated.Last_Parse_Error__c,
            'A successful parse with tags should clear any stale parse error');
    }

    @isTest
    static void testParseAndSaveTags_ThrowsForFileTooLarge() {
        Document_Template__c tpl = createTemplate('Large File Test', 'Account');

        // Create a ContentVersion with size > 5MB is not feasible in test,
        // so we verify the query path when content version is missing
        Boolean exceptionThrown = false;
        try {
            Test.startTest();
            TemplateService.parseAndSaveTags(tpl.Id, 'fakeVersionId');
            Test.stopTest();
        } catch (TemplateService.TemplateParseException e) {
            exceptionThrown = true;
            System.assert(e.getMessage().contains('Could not find template file'),
                'Should mention template file not found');
        }
        System.assertEquals(true, exceptionThrown,
            'Should throw TemplateParseException for missing content version');
    }

    @isTest
    static void testParseAndSaveTagsAsync_WritesErrorOnFailure() {
        Document_Template__c tpl = createTemplate('Async Error Test', 'Account');

        Test.setMock(HttpCalloutMock.class, new MockLambdaFailure());

        Test.startTest();
        TemplateService.parseAndSaveTagsAsync(tpl.Id, 'nonExistentCvId');
        Test.stopTest();

        Document_Template__c updated = [
            SELECT Last_Parse_Error__c FROM Document_Template__c WHERE Id = :tpl.Id
        ];
        System.assertNotEquals(null, updated.Last_Parse_Error__c,
            'Last_Parse_Error__c should be written on async failure');
    }

    // ─── listTemplates Tests ───────────────────────────────────────────────────

    @isTest
    static void testListTemplates_ReturnsAllTemplates() {
        createTemplate('Template A', 'Account');
        createTemplate('Template B', 'Contact');
        createTemplate('Template C', 'Opportunity');

        Test.startTest();
        List<Document_Template__c> results = TemplateService.listTemplates();
        Test.stopTest();

        System.assert(results.size() >= 3, 'Should return at least 3 templates');
    }

    @isTest
    static void testListTemplates_IsSortedByCreatedDateDesc() {
        createTemplate('Zebra Template', 'Account');
        createTemplate('Alpha Template', 'Contact');

        Test.startTest();
        List<Document_Template__c> results = TemplateService.listTemplates();
        Test.stopTest();

        // The library grid shows newest first.
        for (Integer i = 1; i < results.size(); i++) {
            System.assert(
                results[i - 1].CreatedDate >= results[i].CreatedDate,
                'Templates should be sorted by CreatedDate DESC'
            );
        }
    }

    // ─── getTemplate Tests ─────────────────────────────────────────────────────

    @isTest
    static void testGetTemplate_ReturnsTemplateAndFields() {
        Document_Template__c tpl = createTemplate('Detail Test', 'Account');

        Document_Template_Field__c field = new Document_Template_Field__c();
        field.Document_Template__c = tpl.Id;
        field.Tag_Name__c          = 'Name';
        field.Field_Type__c        = 'Field';
        field.Required__c          = true;
        insert field;

        Test.startTest();
        Map<String, Object> result = TemplateService.getTemplate(tpl.Id);
        Test.stopTest();

        System.assertNotEquals(null, result.get('template'), 'Should return template');
        System.assertNotEquals(null, result.get('fields'),   'Should return fields');

        List<Object> fields = (List<Object>) result.get('fields');
        System.assertEquals(1, fields.size(), 'Should return 1 field');
    }

    // ─── getEligibleTemplates Tests ────────────────────────────────────────────

    @isTest
    static void testGetEligibleTemplates_ReturnsOnlyActiveTemplatesWithFile() {
        ContentVersion cv = createContentVersion('EligibleDoc');

        Document_Template__c active = createTemplate('Active Tpl', 'Account');
        active.Template_File_Id__c = cv.Id;
        update active;

        Document_Template__c inactive = createTemplate('Inactive Tpl', 'Account');
        inactive.Active__c = false;
        update inactive;

        Document_Template__c noFile = createTemplate('No File Tpl', 'Account');

        Test.startTest();
        List<Document_Template__c> results = TemplateService.getEligibleTemplates('Account');
        Test.stopTest();

        System.assertEquals(1, results.size(),
            'Only the active template that has a file should be eligible');
        for (Document_Template__c t : results) {
            System.assertEquals('Active Tpl', t.Name,
                'Inactive templates and templates with no file must be excluded');
        }
    }

    @isTest
    static void testGetEligibleTemplates_ReturnsEmptyForBlankObjectName() {
        Test.startTest();
        List<Document_Template__c> results = TemplateService.getEligibleTemplates('');
        Test.stopTest();

        System.assertEquals(0, results.size(), 'Should return empty list for blank object name');
    }

    @isTest
    static void testGetEligibleTemplates_ExcludesTemplatesWithParseErrors() {
        ContentVersion cv = createContentVersion('ErrorDoc');

        Document_Template__c errTpl = createTemplate('Error Tpl', 'Account');
        errTpl.Template_File_Id__c = cv.Id;
        errTpl.Last_Parse_Error__c = 'Some parse error';
        update errTpl;

        Test.startTest();
        List<Document_Template__c> results = TemplateService.getEligibleTemplates('Account');
        Test.stopTest();

        for (Document_Template__c t : results) {
            System.assert(String.isBlank(t.Last_Parse_Error__c),
                'Templates with parse errors should be excluded');
        }
    }

    // ─── deleteTemplate Tests ──────────────────────────────────────────────────

    @isTest
    static void testDeleteTemplate_DeletesSuccessfully() {
        Document_Template__c tpl = createTemplate('Delete Me', 'Account');

        Test.startTest();
        TemplateService.deleteTemplate(tpl.Id);
        Test.stopTest();

        Integer count = [
            SELECT COUNT() FROM Document_Template__c WHERE Id = :tpl.Id
        ];
        System.assertEquals(0, count, 'Template should be deleted');
    }

    // ─── updateFieldRequired Tests ─────────────────────────────────────────────

    @isTest
    static void testUpdateFieldRequired_UpdatesFlag() {
        Document_Template__c tpl = createTemplate('Field Update Test', 'Account');

        Document_Template_Field__c field = new Document_Template_Field__c();
        field.Document_Template__c = tpl.Id;
        field.Tag_Name__c          = 'TestTag';
        field.Field_Type__c        = 'Field';
        field.Required__c          = true;
        insert field;

        Test.startTest();
        TemplateService.updateFieldRequired(field.Id, false);
        Test.stopTest();

        Document_Template_Field__c updated = [
            SELECT Required__c FROM Document_Template_Field__c WHERE Id = :field.Id
        ];
        System.assertEquals(false, updated.Required__c,
            'Required flag should be updated to false');
    }

    // ─── getTemplatePreviewUrl Tests ───────────────────────────────────────────

    @isTest
    static void testGetTemplatePreviewUrl_ReturnsUrlOnSuccess() {
        ContentVersion cv = createContentVersion('PreviewDoc');
        Document_Template__c tpl = createTemplate('Preview Test', 'Account');
        tpl.Template_File_Id__c = cv.Id;
        update tpl;

        Test.setMock(HttpCalloutMock.class, new MockLambdaPreviewSuccess());

        Test.startTest();
        String url = TemplateService.getTemplatePreviewUrl(tpl.Id, null);
        Test.stopTest();

        System.assertNotEquals(null, url,   'Should return a URL');
        System.assert(url.startsWith('https://'), 'URL should be HTTPS');
    }

    @isTest
    static void testGetTemplatePreviewUrl_ThrowsForNullTemplateId() {
        Boolean exceptionThrown = false;
        try {
            Test.startTest();
            TemplateService.getTemplatePreviewUrl(null, null);
            Test.stopTest();
        } catch (AuraHandledException e) {
            exceptionThrown = true;
        }
        System.assertEquals(true, exceptionThrown,
            'Should throw when neither a template Id nor a ContentVersion Id is given');
    }

    @isTest
    static void testGetTemplatePreviewUrl_ThrowsWhenNoFile() {
        Document_Template__c tpl = createTemplate('No File Preview', 'Account');

        Boolean exceptionThrown = false;
        try {
            Test.startTest();
            TemplateService.getTemplatePreviewUrl(tpl.Id, null);
            Test.stopTest();
        } catch (AuraHandledException e) {
            exceptionThrown = true;
        }
        System.assertEquals(true, exceptionThrown,
            'Should throw when template has no file');
    }

    @isTest
    static void testGetTemplatePreviewUrl_ThrowsOnLambdaFailure() {
        ContentVersion cv = createContentVersion('LambdaFailDoc');
        Document_Template__c tpl = createTemplate('Lambda Fail Preview', 'Account');
        tpl.Template_File_Id__c = cv.Id;
        update tpl;

        Test.setMock(HttpCalloutMock.class, new MockLambdaFailure());

        Boolean exceptionThrown = false;
        try {
            Test.startTest();
            TemplateService.getTemplatePreviewUrl(tpl.Id, null);
            Test.stopTest();
        } catch (AuraHandledException e) {
            exceptionThrown = true;
        }
        System.assertEquals(true, exceptionThrown,
            'Should throw on Lambda HTTP failure');
    }

    @isTest
    static void testGetTemplatePreviewUrl_ThrowsWhenUrlMissingInResponse() {
        ContentVersion cv = createContentVersion('NoUrlDoc');
        Document_Template__c tpl = createTemplate('No URL Preview', 'Account');
        tpl.Template_File_Id__c = cv.Id;
        update tpl;

        Test.setMock(HttpCalloutMock.class, new MockLambdaPreviewNoUrl());

        Boolean exceptionThrown = false;
        try {
            Test.startTest();
            TemplateService.getTemplatePreviewUrl(tpl.Id, null);
            Test.stopTest();
        } catch (AuraHandledException e) {
            exceptionThrown = true;

        }
        System.assertEquals(true, exceptionThrown,
            'Should throw when Lambda returns no URL');
    }

    // ─── Stored PDF preview (TemplatePreviewPdfQueueable) ──────────────────────

    // Two-callout chain: convertToPdf → {success,url}, then proxyUrl → {pdfBase64}.
    private class MockTemplatePreviewChain implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            String body = req.getBody();
            if (body != null && body.contains('proxyUrl')) {
                res.setBody(JSON.serialize(new Map<String, Object>{
                    'pdfBase64' => EncodingUtil.base64Encode(Blob.valueOf('FAKE-PDF-BYTES'))
                }));
            } else {
                res.setBody(JSON.serialize(new Map<String, Object>{
                    'success' => true,
                    'url'     => 'https://s3.amazonaws.com/preview/test.pdf'
                }));
            }
            return res;
        }
    }

    @isTest
    static void testTemplatePreviewPdfQueueable_buildsStoredPreview() {
        ContentVersion cv = createContentVersion('QPreviewDoc');
        Document_Template__c tpl = createTemplate('Queueable Preview', 'Account');
        tpl.Template_File_Id__c = cv.Id;
        update tpl;

        Test.setMock(HttpCalloutMock.class, new MockTemplatePreviewChain());

        Test.startTest();
        System.enqueueJob(new TemplatePreviewPdfQueueable(tpl.Id));
        Test.stopTest();

        Id previewCvId = TemplateService.getStoredTemplatePreviewCvId(tpl.Id);
        System.assertNotEquals(null, previewCvId,
            'A stored preview PDF should exist after the queueable runs');
    }

    @isTest
    static void testTemplatePreviewPdfQueueable_noFile_isNoOp() {
        Document_Template__c tpl = createTemplate('Q No File', 'Account');
        Test.startTest();
        System.enqueueJob(new TemplatePreviewPdfQueueable(tpl.Id));
        Test.stopTest();
        System.assertEquals(null, TemplateService.getStoredTemplatePreviewCvId(tpl.Id),
            'No DOCX file → no preview built');
    }

    @isTest
    static void testGetStoredTemplatePreviewCvId_nullWhenNone() {
        Document_Template__c tpl = createTemplate('No Preview Yet', 'Account');
        Test.startTest();
        Id cvId = TemplateService.getStoredTemplatePreviewCvId(tpl.Id);
        Test.stopTest();
        System.assertEquals(null, cvId, 'No preview built yet → null');
    }

    @isTest
    static void testGetStoredTemplatePreviewCvId_nullForNullInput() {
        System.assertEquals(null, TemplateService.getStoredTemplatePreviewCvId(null),
            'Null template id → null');
    }

    // ─── Template Layout (Signers & Fields) Tests ──────────────────────────────

    private static Agreement__c createAgreement(String name) {
        Agreement__c agr = new Agreement__c(Name = name);
        insert agr;
        return agr;
    }

    @isTest
    static void testSaveAndGetTemplateLayout_RoundTrip() {
        Document_Template__c tpl = createTemplate('Layout Round Trip', 'Account');
        String layout = JSON.serialize(new Map<String, Object>{
            'signers' => new List<Object>{
                new Map<String, Object>{
                    'key' => 's1', 'name' => 'Jane Doe', 'email' => 'jane@co.com',
                    'role' => 'Signer', 'order' => 1
                }
            },
            'fields' => new List<Object>()
        });

        Test.startTest();
        TemplateService.saveTemplateLayout(tpl.Id, layout);
        String fetched = TemplateService.getTemplateLayout(tpl.Id);
        Test.stopTest();

        System.assertEquals(layout, fetched,
            'getTemplateLayout should return exactly what saveTemplateLayout stored');

        // The "fields" key must survive the round-trip untouched.
        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(fetched);
        System.assert(parsed.containsKey('fields'),
            'fields key should be preserved on save/get round-trip');
    }

    @isTest
    static void testGetTemplateLayout_ReturnsEmptyWhenUnset() {
        Document_Template__c tpl = createTemplate('No Layout Yet', 'Account');
        Test.startTest();
        String fetched = TemplateService.getTemplateLayout(tpl.Id);
        Test.stopTest();
        System.assertEquals('', fetched,
            'getTemplateLayout should return empty string when layout is unset');
    }

    @isTest
    static void testGetTemplateLayout_ReturnsEmptyForNullId() {
        System.assertEquals('', TemplateService.getTemplateLayout(null),
            'Null template id → empty string');
    }

    @isTest
    static void testSaveTemplateLayout_ThrowsForNullId() {
        Boolean exceptionThrown = false;
        try {
            TemplateService.saveTemplateLayout(null, '{}');
        } catch (AuraHandledException e) {
            exceptionThrown = true;
        }
        System.assertEquals(true, exceptionThrown,
            'saveTemplateLayout should throw for null template id');
    }

    @isTest
    static void testMaterializeSignersAndFields_CreatesSignerAndField() {
        Document_Template__c tpl = createTemplate('Materialize Test', 'Account');
        Agreement__c agr = createAgreement('Materialize Agreement');

        String layout = JSON.serialize(new Map<String, Object>{
            'signers' => new List<Object>{
                new Map<String, Object>{
                    'key' => 's1', 'name' => 'Jane Doe', 'email' => 'jane@co.com',
                    'role' => 'Signer', 'order' => 1
                }
            },
            'fields' => new List<Object>{
                new Map<String, Object>{
                    'signerKey' => 's1',
                    'type'      => 'Signature',
                    'label'     => 'Sign Here',
                    'page'      => 1,
                    'x'         => 100,
                    'y'         => 200,
                    'width'     => 150,
                    'height'    => 40,
                    'pageWidth' => 762,
                    'required'  => true
                }
            }
        });
        TemplateService.saveTemplateLayout(tpl.Id, layout);

        Test.startTest();
        TemplateService.materializeSignersAndFields(agr.Id, tpl.Id);
        Test.stopTest();

        List<Signer__c> signers = [
            SELECT Id, Name, Email__c, Role__c, Status__c, Signing_Order__c
            FROM Signer__c WHERE Agreement__c = :agr.Id
        ];
        System.assertEquals(1, signers.size(), 'Should materialize exactly 1 signer');
        System.assertEquals('jane@co.com', signers[0].Email__c, 'Email should match layout');
        System.assertEquals('Signer',      signers[0].Role__c,  'Role should match layout');
        System.assertEquals('Pending',     signers[0].Status__c,'Status should default to Pending');
        System.assertEquals(1,             signers[0].Signing_Order__c, 'Order should match layout');

        List<Signature_Field__c> fields = [
            SELECT Id, Field_Type__c, Field_Label__c, Assigned_Signer__c,
                   Page_Number__c, X_Position__c, Y_Position__c, Width__c,
                   Height__c, Page_Width__c, Is_Required__c
            FROM Signature_Field__c WHERE Agreement__c = :agr.Id
        ];
        System.assertEquals(1, fields.size(), 'Should materialize exactly 1 field');
        System.assertEquals(signers[0].Id, fields[0].Assigned_Signer__c,
            'Field should be linked to the materialized signer via the key map');
        System.assertEquals('Signature', fields[0].Field_Type__c, 'Field type should match layout');
        System.assertEquals(true,         fields[0].Is_Required__c, 'Required flag should match layout');
        System.assertEquals(762,          fields[0].Page_Width__c,  'Page width should match layout');
    }

    @isTest
    static void testMaterializeSignersAndFields_SkipsFieldWithUnmatchedSignerKey() {
        Document_Template__c tpl = createTemplate('Unmatched Key Test', 'Account');
        Agreement__c agr = createAgreement('Unmatched Key Agreement');

        String layout = JSON.serialize(new Map<String, Object>{
            'signers' => new List<Object>{
                new Map<String, Object>{
                    'key' => 's1', 'name' => 'Jane Doe', 'email' => 'jane@co.com',
                    'role' => 'Signer', 'order' => 1
                }
            },
            'fields' => new List<Object>{
                new Map<String, Object>{
                    'signerKey' => 'DOES_NOT_EXIST',
                    'type'      => 'Signature',
                    'label'     => 'Orphan',
                    'page'      => 1
                }
            }
        });
        TemplateService.saveTemplateLayout(tpl.Id, layout);

        Test.startTest();
        TemplateService.materializeSignersAndFields(agr.Id, tpl.Id);
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Signer__c WHERE Agreement__c = :agr.Id],
            'Signer should still be created');
        System.assertEquals(0, [SELECT COUNT() FROM Signature_Field__c WHERE Agreement__c = :agr.Id],
            'Field with unmatched signerKey should be skipped');
    }

    @isTest
    static void testMaterializeSignersAndFields_NoOpWhenLayoutBlank() {
        Document_Template__c tpl = createTemplate('Blank Layout Test', 'Account');
        Agreement__c agr = createAgreement('Blank Layout Agreement');

        Test.startTest();
        TemplateService.materializeSignersAndFields(agr.Id, tpl.Id);
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Signer__c WHERE Agreement__c = :agr.Id],
            'No signers should be created when the layout is blank');
    }

    @isTest
    static void testMaterializeSignersAndFields_NoOpWhenNoSigners() {
        Document_Template__c tpl = createTemplate('No Signers Test', 'Account');
        Agreement__c agr = createAgreement('No Signers Agreement');

        String layout = JSON.serialize(new Map<String, Object>{
            'signers' => new List<Object>(),
            'fields'  => new List<Object>()
        });
        TemplateService.saveTemplateLayout(tpl.Id, layout);

        Test.startTest();
        TemplateService.materializeSignersAndFields(agr.Id, tpl.Id);
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Signer__c WHERE Agreement__c = :agr.Id],
            'No signers should be created when signers[] is empty');
    }

    @isTest
    static void testMaterializeSignersAndFields_SkipsSignerWithoutEmail() {
        Document_Template__c tpl = createTemplate('No Email Test', 'Account');
        Agreement__c agr = createAgreement('No Email Agreement');

        String layout = JSON.serialize(new Map<String, Object>{
            'signers' => new List<Object>{
                new Map<String, Object>{ 'key' => 's1', 'name' => 'No Email', 'role' => 'Signer', 'order' => 1 },
                new Map<String, Object>{ 'key' => 's2', 'name' => 'Has Email', 'email' => 'has@co.com', 'role' => 'CC', 'order' => 2 }
            },
            'fields' => new List<Object>()
        });
        TemplateService.saveTemplateLayout(tpl.Id, layout);

        Test.startTest();
        TemplateService.materializeSignersAndFields(agr.Id, tpl.Id);
        Test.stopTest();

        List<Signer__c> signers = [
            SELECT Email__c, Role__c FROM Signer__c WHERE Agreement__c = :agr.Id
        ];
        System.assertEquals(1, signers.size(),
            'Signer missing the required Email__c should be skipped');
        System.assertEquals('has@co.com', signers[0].Email__c, 'Only the signer with an email should be created');
        System.assertEquals('CC',         signers[0].Role__c,  'CC role should be honored');
    }

    @isTest
    static void testMaterializeSignersAndFields_NoOpForNullIds() {
        // Best-effort: should swallow / no-op rather than throw.
        Test.startTest();
        TemplateService.materializeSignersAndFields(null, null);
        Test.stopTest();
        // Reaching here without an exception is the assertion.
        System.assert(true, 'Null ids should be a safe no-op');
    }

    // ─── getRecordEmailFields Tests ────────────────────────────────────────────

    @isTest
    static void testGetRecordEmailFields_ReturnsEmailFieldOfRecord() {
        Contact c = new Contact(LastName = 'Email Test', Email = 'rec@co.com');
        insert c;

        Test.startTest();
        List<TemplateService.EmailField> result =
            TemplateService.getRecordEmailFields(c.Id);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Result should not be null');
        System.assert(result.size() >= 1,
            'Contact has at least one Email-type field');

        Boolean foundEmail = false;
        for (TemplateService.EmailField ef : result) {
            System.assertNotEquals(null, ef.apiName, 'apiName should be populated');
            System.assertNotEquals(null, ef.label,   'label should be populated');
            if (ef.apiName == 'Email') {
                foundEmail = true;
                System.assertEquals('rec@co.com', ef.value,
                    'The standard Email field should carry the record value');
            }
        }
        System.assert(foundEmail,
            'The standard Contact Email field should be returned');
    }

    @isTest
    static void testGetRecordEmailFields_ReturnsEmptyForNullId() {
        Test.startTest();
        List<TemplateService.EmailField> result =
            TemplateService.getRecordEmailFields(null);
        Test.stopTest();

        System.assertNotEquals(null, result, 'Should return a list, not null');
        System.assertEquals(0, result.size(),
            'Null record id should return an empty list');
    }

    @isTest
    static void testGetRelatedObjectFields_PrefixedTagsAndBlankGuards() {
        Test.startTest();
        // Parent-relationship style: prefixed tags like {{Owner.Field}}
        List<Map<String, Object>> rel =
            TemplateService.getRelatedObjectFields('Contact', 'Owner.');
        // Child-loop style: bare tags like {{Field}}
        List<Map<String, Object>> child =
            TemplateService.getRelatedObjectFields('Contact', '');
        List<Map<String, Object>> blank =
            TemplateService.getRelatedObjectFields('', 'X.');
        List<Map<String, Object>> bogus =
            TemplateService.getRelatedObjectFields('NoSuchObject__x', '');
        Test.stopTest();

        System.assert(rel.size() > 0, 'Contact should expose accessible fields');
        for (Map<String, Object> f : rel) {
            System.assert(((String) f.get('tag')).startsWith('{{Owner.'),
                'Prefixed tag expected, got ' + f.get('tag'));
        }
        System.assert(child.size() > 0, 'Bare field list expected');
        System.assert(((String) child[0].get('tag')).startsWith('{{')
            && !((String) child[0].get('tag')).startsWith('{{Owner.'),
            'Child tags should be unprefixed');
        System.assertEquals(0, blank.size(), 'Blank object -> empty list');
        System.assertEquals(0, bogus.size(), 'Unknown object -> empty list');
    }

    // ─── materializeSignersAndFieldsMapped Tests ───────────────────────────────

    @isTest
    static void testMaterializeSignersAndFieldsMapped_OverridesSignerEmail() {
        Document_Template__c tpl = createTemplate('Mapped Override Test', 'Account');
        Agreement__c agr = createAgreement('Mapped Override Agreement');

        String layout = JSON.serialize(new Map<String, Object>{
            'signers' => new List<Object>{
                new Map<String, Object>{
                    'key' => 's1', 'name' => 'Jane Doe', 'email' => 'old@x.com',
                    'role' => 'Signer', 'order' => 1
                }
            },
            'fields' => new List<Object>()
        });
        TemplateService.saveTemplateLayout(tpl.Id, layout);

        String mappingJson = JSON.serialize(new Map<String, Object>{
            'signers' => new Map<String, Object>{
                's1' => new Map<String, Object>{ 'email' => 'new@y.com' }
            }
        });

        Test.startTest();
        TemplateService.materializeSignersAndFieldsMapped(agr.Id, tpl.Id, mappingJson);
        Test.stopTest();

        List<Signer__c> signers = [
            SELECT Email__c, Name FROM Signer__c WHERE Agreement__c = :agr.Id
        ];
        System.assertEquals(1, signers.size(), 'Should materialize exactly 1 signer');
        System.assertEquals('new@y.com', signers[0].Email__c,
            'Override email should replace the layout email');
        System.assertEquals('Jane Doe', signers[0].Name,
            'Name should fall back to the layout value when not overridden');
    }

    @isTest
    static void testMaterializeSignersAndFieldsMapped_OverridesNameAndEmail() {
        Document_Template__c tpl = createTemplate('Mapped Name Test', 'Account');
        Agreement__c agr = createAgreement('Mapped Name Agreement');

        String layout = JSON.serialize(new Map<String, Object>{
            'signers' => new List<Object>{
                new Map<String, Object>{
                    'key' => 's1', 'name' => 'Old Name', 'email' => 'old@x.com',
                    'role' => 'Signer', 'order' => 1
                }
            },
            'fields' => new List<Object>()
        });
        TemplateService.saveTemplateLayout(tpl.Id, layout);

        String mappingJson = JSON.serialize(new Map<String, Object>{
            'signers' => new Map<String, Object>{
                's1' => new Map<String, Object>{ 'name' => 'New Name', 'email' => 'new@y.com' }
            }
        });

        Test.startTest();
        TemplateService.materializeSignersAndFieldsMapped(agr.Id, tpl.Id, mappingJson);
        Test.stopTest();

        List<Signer__c> signers = [
            SELECT Email__c, Name FROM Signer__c WHERE Agreement__c = :agr.Id
        ];
        System.assertEquals(1, signers.size(), 'Should materialize exactly 1 signer');
        System.assertEquals('new@y.com', signers[0].Email__c, 'Email override should win');
        System.assertEquals('New Name',  signers[0].Name,     'Name override should win');
    }

    @isTest
    static void testMaterializeSignersAndFieldsMapped_NullMappingUsesLayout() {
        Document_Template__c tpl = createTemplate('Mapped Null Test', 'Account');
        Agreement__c agr = createAgreement('Mapped Null Agreement');

        String layout = JSON.serialize(new Map<String, Object>{
            'signers' => new List<Object>{
                new Map<String, Object>{
                    'key' => 's1', 'name' => 'Jane Doe', 'email' => 'jane@co.com',
                    'role' => 'Signer', 'order' => 1
                }
            },
            'fields' => new List<Object>()
        });
        TemplateService.saveTemplateLayout(tpl.Id, layout);

        Test.startTest();
        // Null mappingJson → falls back to layout values entirely.
        TemplateService.materializeSignersAndFieldsMapped(agr.Id, tpl.Id, null);
        Test.stopTest();

        List<Signer__c> signers = [
            SELECT Email__c FROM Signer__c WHERE Agreement__c = :agr.Id
        ];
        System.assertEquals(1, signers.size(), 'Should materialize the layout signer');
        System.assertEquals('jane@co.com', signers[0].Email__c,
            'Null mapping should use the layout email');
    }

    @isTest
    static void testMaterializeSignersAndFieldsMapped_BackwardCompatFlatShape() {
        // An OLD flat signer-overrides map (NEITHER "signers" NOR "fieldEmails"
        // key) must still be honored as per-signer overrides.
        Document_Template__c tpl = createTemplate('Mapped Compat Test', 'Account');
        Agreement__c agr = createAgreement('Mapped Compat Agreement');

        String layout = JSON.serialize(new Map<String, Object>{
            'signers' => new List<Object>{
                new Map<String, Object>{
                    'key' => 's1', 'name' => 'Jane Doe', 'email' => 'old@x.com',
                    'role' => 'Signer', 'order' => 1
                }
            },
            'fields' => new List<Object>()
        });
        TemplateService.saveTemplateLayout(tpl.Id, layout);

        // Old flat shape: top-level keys are signer keys, not "signers".
        String mappingJson = JSON.serialize(new Map<String, Object>{
            's1' => new Map<String, Object>{ 'email' => 'compat@y.com' }
        });

        Test.startTest();
        TemplateService.materializeSignersAndFieldsMapped(agr.Id, tpl.Id, mappingJson);
        Test.stopTest();

        List<Signer__c> signers = [
            SELECT Email__c FROM Signer__c WHERE Agreement__c = :agr.Id
        ];
        System.assertEquals(1, signers.size(), 'Should materialize exactly 1 signer');
        System.assertEquals('compat@y.com', signers[0].Email__c,
            'Old flat-shape override email should still be applied');
    }

    @isTest
    static void testMaterializeSignersAndFieldsMapped_UnassignedFieldsCollapseToOneSigner() {
        // 1 defined signer + 2 UNASSIGNED fields. fieldEmails assigns the SAME
        // email to both unassigned fields → they must collapse to ONE new
        // Signer__c, plus the defined signer (2 signers total), and both
        // unassigned fields must be created & assigned to the new signer.
        Document_Template__c tpl = createTemplate('Unassigned Collapse Test', 'Account');
        Agreement__c agr = createAgreement('Unassigned Collapse Agreement');

        String layout = JSON.serialize(new Map<String, Object>{
            'signers' => new List<Object>{
                new Map<String, Object>{
                    'key' => 's1', 'name' => 'Defined Signer', 'email' => 'defined@co.com',
                    'role' => 'Signer', 'order' => 1
                }
            },
            'fields' => new List<Object>{
                // index 0 — assigned to the defined signer
                new Map<String, Object>{
                    'signerKey' => 's1', 'type' => 'Signature', 'label' => 'Defined Sign',
                    'page' => 1, 'x' => 10, 'y' => 20, 'width' => 100, 'height' => 30,
                    'pageWidth' => 762, 'required' => true
                },
                // index 1 — UNASSIGNED (blank signerKey)
                new Map<String, Object>{
                    'signerKey' => '', 'type' => 'Signature', 'label' => 'Unassigned A',
                    'page' => 1, 'x' => 40, 'y' => 50, 'width' => 100, 'height' => 30,
                    'pageWidth' => 762, 'required' => true
                },
                // index 2 — UNASSIGNED (no signerKey key at all)
                new Map<String, Object>{
                    'type' => 'Date Signed', 'label' => 'Unassigned B',
                    'page' => 2, 'x' => 60, 'y' => 70, 'width' => 100, 'height' => 30,
                    'pageWidth' => 762, 'required' => false
                }
            }
        });
        TemplateService.saveTemplateLayout(tpl.Id, layout);

        // fieldEmails keyed by 0-based index in fields[]: both unassigned
        // fields (indices 1 and 2) get the SAME email → dedupe to ONE signer.
        String mappingJson = JSON.serialize(new Map<String, Object>{
            'signers'     => new Map<String, Object>(),
            'fieldEmails' => new Map<String, Object>{
                '1' => 'a@x.com',
                '2' => 'a@x.com'
            }
        });

        Test.startTest();
        TemplateService.materializeSignersAndFieldsMapped(agr.Id, tpl.Id, mappingJson);
        Test.stopTest();

        List<Signer__c> signers = [
            SELECT Id, Email__c FROM Signer__c WHERE Agreement__c = :agr.Id
        ];
        System.assertEquals(2, signers.size(),
            'Defined signer + ONE deduped signer for the shared unassigned email');

        // Find the new signer (email a@x.com) and the defined one.
        Id newSignerId = null;
        Id definedSignerId = null;
        for (Signer__c s : signers) {
            if (s.Email__c == 'a@x.com')        newSignerId = s.Id;
            if (s.Email__c == 'defined@co.com') definedSignerId = s.Id;
        }
        System.assertNotEquals(null, newSignerId,
            'A single signer with the shared unassigned email should exist');
        System.assertNotEquals(null, definedSignerId,
            'The defined signer should still exist');

        List<Signature_Field__c> fields = [
            SELECT Field_Label__c, Assigned_Signer__c
            FROM Signature_Field__c WHERE Agreement__c = :agr.Id
        ];
        System.assertEquals(3, fields.size(),
            'All 3 fields (1 defined + 2 unassigned-with-email) should be created');

        Integer assignedToNew = 0;
        Integer assignedToDefined = 0;
        for (Signature_Field__c f : fields) {
            if (f.Assigned_Signer__c == newSignerId)     assignedToNew++;
            if (f.Assigned_Signer__c == definedSignerId) assignedToDefined++;
        }
        System.assertEquals(2, assignedToNew,
            'Both unassigned fields should be assigned to the single new signer');
        System.assertEquals(1, assignedToDefined,
            'The defined field should remain assigned to the defined signer');
    }

    @isTest
    static void testMaterializeSignersAndFieldsMapped_UnassignedFieldWithoutEmailSkipped() {
        // An unassigned field with NO fieldEmail entry must still be skipped.
        Document_Template__c tpl = createTemplate('Unassigned Skip Test', 'Account');
        Agreement__c agr = createAgreement('Unassigned Skip Agreement');

        String layout = JSON.serialize(new Map<String, Object>{
            'signers' => new List<Object>{
                new Map<String, Object>{
                    'key' => 's1', 'name' => 'Defined Signer', 'email' => 'defined@co.com',
                    'role' => 'Signer', 'order' => 1
                }
            },
            'fields' => new List<Object>{
                // index 0 — assigned to the defined signer
                new Map<String, Object>{
                    'signerKey' => 's1', 'type' => 'Signature', 'label' => 'Defined Sign',
                    'page' => 1, 'x' => 10, 'y' => 20, 'width' => 100, 'height' => 30,
                    'pageWidth' => 762, 'required' => true
                },
                // index 1 — UNASSIGNED with NO fieldEmail → must be skipped
                new Map<String, Object>{
                    'signerKey' => '', 'type' => 'Initial', 'label' => 'Orphan',
                    'page' => 1, 'x' => 40, 'y' => 50, 'width' => 100, 'height' => 30,
                    'pageWidth' => 762, 'required' => true
                }
            }
        });
        TemplateService.saveTemplateLayout(tpl.Id, layout);

        // fieldEmails covers only index 0 (which is already assigned via key),
        // leaving the unassigned index-1 field with no email.
        String mappingJson = JSON.serialize(new Map<String, Object>{
            'signers'     => new Map<String, Object>(),
            'fieldEmails' => new Map<String, Object>{ '5' => 'noone@x.com' }
        });

        Test.startTest();
        TemplateService.materializeSignersAndFieldsMapped(agr.Id, tpl.Id, mappingJson);
        Test.stopTest();

        // The synthesized signer (noone@x.com) is created because its email is
        // referenced, but the index-1 field still has no fieldEmail and stays
        // dropped.
        List<Signature_Field__c> fields = [
            SELECT Field_Label__c FROM Signature_Field__c WHERE Agreement__c = :agr.Id
        ];
        System.assertEquals(1, fields.size(),
            'Only the defined field is created; the unassigned no-email field is skipped');
        System.assertEquals('Defined Sign', fields[0].Field_Label__c,
            'The surviving field is the defined-signer one');
    }

    @isTest
    static void testMaterializeSignersAndFields_StillDelegatesUnchanged() {
        // The existing 2-arg method must keep working via delegation to
        // doMaterialize(.., null).
        Document_Template__c tpl = createTemplate('Delegation Test', 'Account');
        Agreement__c agr = createAgreement('Delegation Agreement');

        String layout = JSON.serialize(new Map<String, Object>{
            'signers' => new List<Object>{
                new Map<String, Object>{
                    'key' => 's1', 'name' => 'Jane Doe', 'email' => 'jane@co.com',
                    'role' => 'Signer', 'order' => 1
                }
            },
            'fields' => new List<Object>{
                new Map<String, Object>{
                    'signerKey' => 's1', 'type' => 'Signature', 'label' => 'Sign',
                    'page' => 1, 'x' => 100, 'y' => 200, 'width' => 150,
                    'height' => 40, 'pageWidth' => 762, 'required' => true
                }
            }
        });
        TemplateService.saveTemplateLayout(tpl.Id, layout);

        Test.startTest();
        TemplateService.materializeSignersAndFields(agr.Id, tpl.Id);
        Test.stopTest();

        List<Signer__c> signers = [
            SELECT Email__c FROM Signer__c WHERE Agreement__c = :agr.Id
        ];
        System.assertEquals(1, signers.size(),
            'Delegation: 2-arg method should still create the signer');
        System.assertEquals('jane@co.com', signers[0].Email__c,
            'Delegation: layout email should be used unchanged');
        System.assertEquals(1,
            [SELECT COUNT() FROM Signature_Field__c WHERE Agreement__c = :agr.Id],
            'Delegation: the field should still be materialized');
    }
}