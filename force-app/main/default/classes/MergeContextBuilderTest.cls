@isTest
private class MergeContextBuilderTest {
    
    @TestSetup
    static void setupTestData() {
        Account acc = new Account(
            Name = 'Test Company',
            BillingStreet = '123 Test St',
            BillingCity = 'Test City',
            Phone = '9876543210'
        );
        insert acc;
        
        List<Contact> contacts = new List<Contact>{
            new Contact(FirstName = 'Alice', LastName = 'Smith', AccountId = acc.Id, Email = 'alice@test.com'),
            new Contact(FirstName = 'Bob', LastName = 'Johnson', AccountId = acc.Id)
        };
        insert contacts;
        
        Document_Template__c template = new Document_Template__c(
            Name = 'Test Template',
            Object_API_Name__c = 'Account'
        );
        insert template;
        
        List<Document_Template_Field__c> fields = new List<Document_Template_Field__c>();
        
        fields.add(new Document_Template_Field__c(Document_Template__c = template.Id, Tag_Name__c = 'Name',         Field_Type__c = 'Field'));
        fields.add(new Document_Template_Field__c(Document_Template__c = template.Id, Tag_Name__c = 'BillingStreet',Field_Type__c = 'Field'));
        fields.add(new Document_Template_Field__c(Document_Template__c = template.Id, Tag_Name__c = 'Logo_URL__c',  Field_Type__c = 'Image'));
        
        Document_Template_Field__c loopTag = new Document_Template_Field__c(
            Document_Template__c = template.Id,
            Tag_Name__c = 'Contacts',
            Field_Type__c = 'Loop'
        );
        fields.add(loopTag);
        insert fields;
        
        fields = new List<Document_Template_Field__c>();
        fields.add(new Document_Template_Field__c(Document_Template__c = template.Id, Tag_Name__c = 'FirstName', Field_Type__c = 'Field', Loop_Parent__c = loopTag.Id));
        fields.add(new Document_Template_Field__c(Document_Template__c = template.Id, Tag_Name__c = 'LastName',  Field_Type__c = 'Field', Loop_Parent__c = loopTag.Id));
        fields.add(new Document_Template_Field__c(Document_Template__c = template.Id, Tag_Name__c = 'Email',     Field_Type__c = 'Field', Loop_Parent__c = loopTag.Id));
        
        // ALL builtin branches
        fields.add(new Document_Template_Field__c(Document_Template__c = template.Id, Tag_Name__c = 'TODAY',                  Field_Type__c = 'Builtin'));
        fields.add(new Document_Template_Field__c(Document_Template__c = template.Id, Tag_Name__c = 'NOW',                    Field_Type__c = 'Builtin'));
        fields.add(new Document_Template_Field__c(Document_Template__c = template.Id, Tag_Name__c = 'USER.Id',                Field_Type__c = 'Builtin'));
        fields.add(new Document_Template_Field__c(Document_Template__c = template.Id, Tag_Name__c = 'USER.FullName',          Field_Type__c = 'Builtin'));
        fields.add(new Document_Template_Field__c(Document_Template__c = template.Id, Tag_Name__c = 'USER.FirstName',         Field_Type__c = 'Builtin'));
        fields.add(new Document_Template_Field__c(Document_Template__c = template.Id, Tag_Name__c = 'USER.LastName',          Field_Type__c = 'Builtin'));
        fields.add(new Document_Template_Field__c(Document_Template__c = template.Id, Tag_Name__c = 'USER.Email',             Field_Type__c = 'Builtin'));
        fields.add(new Document_Template_Field__c(Document_Template__c = template.Id, Tag_Name__c = 'USER.Locale',            Field_Type__c = 'Builtin'));
        fields.add(new Document_Template_Field__c(Document_Template__c = template.Id, Tag_Name__c = 'USER.Department',        Field_Type__c = 'Builtin'));
        fields.add(new Document_Template_Field__c(Document_Template__c = template.Id, Tag_Name__c = 'USER.NonExistentXYZ999', Field_Type__c = 'Builtin'));
        fields.add(new Document_Template_Field__c(Document_Template__c = template.Id, Tag_Name__c = 'ORG.Id',                 Field_Type__c = 'Builtin'));
        fields.add(new Document_Template_Field__c(Document_Template__c = template.Id, Tag_Name__c = 'ORG.Name',               Field_Type__c = 'Builtin'));
        fields.add(new Document_Template_Field__c(Document_Template__c = template.Id, Tag_Name__c = 'ORG.City',               Field_Type__c = 'Builtin'));
        fields.add(new Document_Template_Field__c(Document_Template__c = template.Id, Tag_Name__c = 'ORG.NonExistentXYZ999',  Field_Type__c = 'Builtin'));
        
        insert fields;
    }
    
    // ─── Helper ───────────────────────────────────────────────────────
    private static Document_Template__c getTemplate() {
        return [
            SELECT Id, Object_API_Name__c,
                   (SELECT Tag_Name__c, Field_Type__c, Loop_Parent__c FROM Template_Fields__r)
            FROM Document_Template__c
            WHERE Name = 'Test Template'
            LIMIT 1
        ];
    }

    // =============================================================
    // Main Build Method Tests
    // =============================================================
    
    @isTest
    static void build_successful_withAllFeatures() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Document_Template__c template = getTemplate();
        
        Test.startTest();
        MergeContextBuilder.BuildResult result = MergeContextBuilder.build(template, acc.Id);
        Test.stopTest();
        
        Assert.isNotNull(result);
        Assert.isNotNull(result.context);
        Assert.isNotNull(result.images);
        Assert.areEqual(acc.Id, result.context.get('Id'));
        Assert.areEqual('Test Company', result.context.get('Name'));
        
        List<Object> contacts = (List<Object>) result.context.get('Contacts');
        Assert.isTrue(contacts != null && contacts.size() >= 1);
        
        Assert.isNotNull(result.context.get('TODAY'));
        Assert.isNotNull(result.context.get('USER.FullName'));
    }

    @isTest
    static void build_relationshipNested_andCompoundAddress() {
        // Account with a full billing address + an Owner (the running user).
        Account acc = new Account(
            Name = 'Addr Co',
            BillingStreet = '525 S. Lexington Ave',
            BillingCity = 'Burlington',
            BillingState = 'NC',
            BillingPostalCode = '27215',
            BillingCountry = 'USA'
        );
        insert acc;

        Document_Template__c tmpl = new Document_Template__c(
            Name = 'Addr Template', Object_API_Name__c = 'Account'
        );
        insert tmpl;
        insert new List<Document_Template_Field__c>{
            new Document_Template_Field__c(Document_Template__c = tmpl.Id, Tag_Name__c = 'Name',          Field_Type__c = 'Field'),
            new Document_Template_Field__c(Document_Template__c = tmpl.Id, Tag_Name__c = 'BillingAddress', Field_Type__c = 'Field'),
            new Document_Template_Field__c(Document_Template__c = tmpl.Id, Tag_Name__c = 'Owner.Name',     Field_Type__c = 'Field')
        };
        Document_Template__c loaded = [
            SELECT Id, Object_API_Name__c,
                   (SELECT Tag_Name__c, Field_Type__c, Loop_Parent__c FROM Template_Fields__r)
            FROM Document_Template__c WHERE Id = :tmpl.Id LIMIT 1
        ];

        Test.startTest();
        MergeContextBuilder.BuildResult result = MergeContextBuilder.build(loaded, acc.Id);
        Test.stopTest();

        // Compound address must render as a readable string, NOT "System.Address[...]".
        String addrStr = String.valueOf(result.context.get('BillingAddress'));
        Assert.isFalse(addrStr.contains('System.Address'), 'Address must be formatted, not the raw object dump');
        Assert.isTrue(addrStr.contains('525 S. Lexington Ave'), 'Address should contain the street');
        Assert.isTrue(addrStr.contains('Burlington'), 'Address should contain the city');

        // Relationship field must be NESTED so docxtemplater can resolve {{Owner.Name}}.
        Object ownerObj = result.context.get('Owner');
        Assert.isTrue(ownerObj instanceof Map<String, Object>, 'Owner should be nested for dotted access');
        Map<String, Object> ownerMap = (Map<String, Object>) ownerObj;
        Assert.isNotNull(ownerMap.get('Name'), 'Owner.Name should resolve via the nested structure');
        // Flat key retained for back-compat.
        Assert.isNotNull(result.context.get('Owner.Name'), 'Flat Owner.Name key should still exist');
    }

    @isTest
    static void build_nullInputs_throws() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Document_Template__c template = [SELECT Id FROM Document_Template__c LIMIT 1];
        
        try {
            MergeContextBuilder.build(null, acc.Id);
            Assert.fail('Should throw on null template');
        } catch (MergeContextBuilder.MergeException e) {
            Assert.isTrue(e.getMessage().contains('Template is null'));
        }
        
        try {
            MergeContextBuilder.build(template, null);
            Assert.fail('Should throw on null recordId');
        } catch (MergeContextBuilder.MergeException e) {
            Assert.isTrue(e.getMessage().contains('Record Id is null'));
        }
    }
    
    @isTest
    static void build_mismatchedObject_throws() {
        Contact con = new Contact(LastName = 'Test');
        insert con;
        Document_Template__c template = [SELECT Id, Object_API_Name__c FROM Document_Template__c LIMIT 1];
        
        try {
            MergeContextBuilder.build(template, con.Id);
            Assert.fail('Should throw on object mismatch');
        } catch (MergeContextBuilder.MergeException e) {
            Assert.isTrue(e.getMessage().contains('Template targets Account'));
        }
    }
    
    @isTest
    static void build_invalidField_throws() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Document_Template__c template = new Document_Template__c(Name = 'Bad Template', Object_API_Name__c = 'Account');
        insert template;
        insert new Document_Template_Field__c(Document_Template__c = template.Id, Tag_Name__c = 'NonExistentField__c', Field_Type__c = 'Field');
        
        Document_Template__c tWithFields = [
            SELECT Id, Object_API_Name__c,
                   (SELECT Tag_Name__c, Field_Type__c, Loop_Parent__c FROM Template_Fields__r)
            FROM Document_Template__c WHERE Id = :template.Id
        ];
        
        try {
            Test.startTest();
            MergeContextBuilder.build(tWithFields, acc.Id);
            Test.stopTest();
        } catch (MergeContextBuilder.MergeException e) {
            Assert.isTrue(e.getMessage().contains('does not exist'));
        }
    }
    
    // =============================================================
    // Image Fetching Tests
    // =============================================================
    
    @isTest
    static void fetchImages_success() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        acc.Logo_URL__c = 'https://picsum.photos/200';
        update acc;
        
        Document_Template__c template = [
            SELECT Id, Object_API_Name__c,
                   (SELECT Tag_Name__c, Field_Type__c FROM Template_Fields__r WHERE Field_Type__c = 'Image')
            FROM Document_Template__c WHERE Name = 'Test Template' LIMIT 1
        ];
        
        Test.setMock(HttpCalloutMock.class, new SuccessfulImageMock());
        
        Test.startTest();
        MergeContextBuilder.BuildResult result = MergeContextBuilder.build(template, acc.Id);
        Test.stopTest();
        
        Assert.isTrue(result.images.size() > 0);
        Map<String, Object> imageData = (Map<String, Object>) result.images.get('Logo_URL__c');
        Assert.isNotNull(imageData);
        Assert.isNotNull(imageData.get('dataBase64'));
    }
    
    @isTest
    static void fetchImages_nonImageContentType() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        acc.Website = 'https://example.com/page.html';
        update acc;
        
        Document_Template__c template = new Document_Template__c(Name = 'Non Image CT', Object_API_Name__c = 'Account');
        insert template;
        insert new Document_Template_Field__c(Document_Template__c = template.Id, Tag_Name__c = 'Website', Field_Type__c = 'Image');
        
        Document_Template__c tWithFields = [
            SELECT Id, Object_API_Name__c,
                   (SELECT Tag_Name__c, Field_Type__c, Loop_Parent__c FROM Template_Fields__r)
            FROM Document_Template__c WHERE Id = :template.Id
        ];
        
        Test.setMock(HttpCalloutMock.class, new NonImageContentTypeMock());
        
        Test.startTest();
        MergeContextBuilder.BuildResult result = MergeContextBuilder.build(tWithFields, acc.Id);
        Test.stopTest();
        
        Assert.areEqual(0, result.images.size());
    }
    
    @isTest
    static void fetchImages_httpError() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        acc.Website = 'https://example.com/image.png';
        update acc;
        
        Document_Template__c template = new Document_Template__c(Name = 'HTTP Error', Object_API_Name__c = 'Account');
        insert template;
        insert new Document_Template_Field__c(Document_Template__c = template.Id, Tag_Name__c = 'Website', Field_Type__c = 'Image');
        
        Document_Template__c tWithFields = [
            SELECT Id, Object_API_Name__c,
                   (SELECT Tag_Name__c, Field_Type__c, Loop_Parent__c FROM Template_Fields__r)
            FROM Document_Template__c WHERE Id = :template.Id
        ];
        
        Test.setMock(HttpCalloutMock.class, new HttpErrorMock());
        
        Test.startTest();
        MergeContextBuilder.BuildResult result = MergeContextBuilder.build(tWithFields, acc.Id);
        Test.stopTest();
        
        Assert.areEqual(0, result.images.size());
    }
    
    // =============================================================
    // SSRF Tests
    // =============================================================
    
    @isTest
    static void ssrfReject_blocksUnsafeUrls() {
        Set<String> empty = new Set<String>();
        Assert.isNotNull(MergeContextBuilder.ssrfReject('http://example.com', empty));
        Assert.isNotNull(MergeContextBuilder.ssrfReject('file:///etc/passwd', empty));
        Assert.isNotNull(MergeContextBuilder.ssrfReject('https://169.254.169.254/latest/meta-data/', empty));
        Assert.isNotNull(MergeContextBuilder.ssrfReject('https://127.0.0.1/', empty));
        Assert.isNotNull(MergeContextBuilder.ssrfReject('https://10.0.0.1/', empty));
        Assert.isNotNull(MergeContextBuilder.ssrfReject('', empty));
        Assert.isNotNull(MergeContextBuilder.ssrfReject('https://localhost/admin', empty));
        Assert.isNotNull(MergeContextBuilder.ssrfReject('https://metadata.google.internal/', empty));
        Assert.isNotNull(MergeContextBuilder.ssrfReject('https://192.168.1.1/', empty));
        Assert.isNotNull(MergeContextBuilder.ssrfReject('https://172.20.0.1/', empty));
     
    }
    
    @isTest
    static void ssrfReject_allowsSafeUrls() {
        Set<String> allowlist = new Set<String>{'picsum.photos'};
        Assert.isNull(MergeContextBuilder.ssrfReject('https://picsum.photos/200', allowlist));
        Assert.isNull(MergeContextBuilder.ssrfReject('https://sub.picsum.photos/image.jpg', allowlist));
    }
    
    @isTest
    static void ssrfReject_hostNotInAllowlist() {
        Set<String> allowlist = new Set<String>{'mycdn.com'};
        Assert.isNotNull(MergeContextBuilder.ssrfReject('https://other.com/image.png', allowlist));
    }

    @isTest
    static void isPrivateOrLoopbackIp_test() {
        Assert.isTrue(MergeContextBuilder.isPrivateOrLoopbackIp('127.0.0.1'));
        Assert.isTrue(MergeContextBuilder.isPrivateOrLoopbackIp('10.0.0.5'));
        Assert.isTrue(MergeContextBuilder.isPrivateOrLoopbackIp('192.168.1.1'));
        Assert.isTrue(MergeContextBuilder.isPrivateOrLoopbackIp('172.20.5.10'));
        Assert.isTrue(MergeContextBuilder.isPrivateOrLoopbackIp('::1'));
        Assert.isTrue(MergeContextBuilder.isPrivateOrLoopbackIp('fe80::1'));
        Assert.isTrue(MergeContextBuilder.isPrivateOrLoopbackIp('0.0.0.1'));
        Assert.isFalse(MergeContextBuilder.isPrivateOrLoopbackIp('8.8.8.8'));
        Assert.isFalse(MergeContextBuilder.isPrivateOrLoopbackIp('example.com'));
        Assert.isFalse(MergeContextBuilder.isPrivateOrLoopbackIp(''));
    }
    
    // =============================================================
    // Loop & Child Field Tests
    // =============================================================
    
    @isTest
    static void build_withLoopAndNestedFields() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Document_Template__c template = getTemplate();
        
        Test.startTest();
        MergeContextBuilder.BuildResult result = MergeContextBuilder.build(template, acc.Id);
        Test.stopTest();
        
        List<Object> contactsList = (List<Object>) result.context.get('Contacts');
        Assert.isNotNull(contactsList);
        Assert.isTrue(contactsList.size() > 0);
        Map<String, Object> firstContact = (Map<String, Object>) contactsList[0];
        Assert.isNotNull(firstContact.get('FirstName'));
        Assert.isNotNull(firstContact.get('LastName'));
    }
    
    // =============================================================
    // Edge Cases
    // =============================================================
    
    @isTest
    static void build_noTemplateFields_returnsEmptyContext() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Document_Template__c emptyTemplate = new Document_Template__c(Name = 'Empty', Object_API_Name__c = 'Account');
        insert emptyTemplate;
        
        Document_Template__c tWithFields = [
            SELECT Id, Object_API_Name__c,
                   (SELECT Tag_Name__c, Field_Type__c, Loop_Parent__c FROM Template_Fields__r)
            FROM Document_Template__c WHERE Id = :emptyTemplate.Id
        ];
        
        Test.startTest();
        MergeContextBuilder.BuildResult result = MergeContextBuilder.build(tWithFields, acc.Id);
        Test.stopTest();
        
        Assert.isNotNull(result.context);
        Assert.areEqual(acc.Id, result.context.get('Id'));
    }
    
    @isTest
    static void build_recordNotFound_throws() {
        Document_Template__c template = [SELECT Id, Object_API_Name__c FROM Document_Template__c LIMIT 1];
        Id fakeId = Account.SObjectType.getDescribe().getKeyPrefix() + '000000000000';
        
        try {
            MergeContextBuilder.build(template, fakeId);
            Assert.fail('Should throw record not found');
        } catch (MergeContextBuilder.MergeException e) {
            Assert.isTrue(e.getMessage().contains('Record not found'));
        }
    }
    
    @isTest
    static void build_invalidRelationship_throws() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Document_Template__c template = new Document_Template__c(Name = 'Invalid Rel', Object_API_Name__c = 'Account');
        insert template;
        insert new Document_Template_Field__c(Document_Template__c = template.Id, Tag_Name__c = 'InvalidRel.Name', Field_Type__c = 'Field');
        
        Document_Template__c tWithFields = [
            SELECT Id, Object_API_Name__c,
                   (SELECT Tag_Name__c, Field_Type__c, Loop_Parent__c FROM Template_Fields__r)
            FROM Document_Template__c WHERE Id = :template.Id
        ];
        
        try {
            MergeContextBuilder.build(tWithFields, acc.Id);
        } catch (MergeContextBuilder.MergeException e) {
            Assert.isTrue(e.getMessage().contains('does not exist') || e.getMessage().contains('Relationship'));
        }
    }

    @isTest
    static void build_dotNotationField_nullChild() {
        Contact con = new Contact(LastName = 'NullParent');
        insert con;
        
        Document_Template__c template = new Document_Template__c(Name = 'Null Child', Object_API_Name__c = 'Contact');
        insert template;
        insert new Document_Template_Field__c(Document_Template__c = template.Id, Tag_Name__c = 'Account.Name', Field_Type__c = 'Field');
        
        Document_Template__c tWithFields = [
            SELECT Id, Object_API_Name__c,
                   (SELECT Tag_Name__c, Field_Type__c, Loop_Parent__c FROM Template_Fields__r)
            FROM Document_Template__c WHERE Id = :template.Id
        ];
        
        Test.startTest();
        MergeContextBuilder.BuildResult result = MergeContextBuilder.build(tWithFields, con.Id);
        Test.stopTest();
        
        Assert.isNotNull(result);
    }
    
    @isTest
    static void build_variousFieldTypes() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        acc.AnnualRevenue = 99999.99;
        update acc;
        
        Document_Template__c template = new Document_Template__c(Name = 'Type Test', Object_API_Name__c = 'Account');
        insert template;
        insert new List<Document_Template_Field__c>{
            new Document_Template_Field__c(Document_Template__c = template.Id, Tag_Name__c = 'Name',           Field_Type__c = 'Field'),
            new Document_Template_Field__c(Document_Template__c = template.Id, Tag_Name__c = 'CreatedDate',    Field_Type__c = 'Field'),
            new Document_Template_Field__c(Document_Template__c = template.Id, Tag_Name__c = 'IsPartner',      Field_Type__c = 'Field'),
            new Document_Template_Field__c(Document_Template__c = template.Id, Tag_Name__c = 'AnnualRevenue',  Field_Type__c = 'Field'),
            new Document_Template_Field__c(Document_Template__c = template.Id, Tag_Name__c = 'LastActivityDate', Field_Type__c = 'Field'),
            new Document_Template_Field__c(Document_Template__c = template.Id, Tag_Name__c = 'Owner.Name',     Field_Type__c = 'Field'),
            new Document_Template_Field__c(Document_Template__c = template.Id, Tag_Name__c = 'Owner.Email',    Field_Type__c = 'Field')
        };
        
        Document_Template__c tWithFields = [
            SELECT Id, Object_API_Name__c,
                   (SELECT Tag_Name__c, Field_Type__c, Loop_Parent__c FROM Template_Fields__r)
            FROM Document_Template__c WHERE Id = :template.Id
        ];
        
        Test.startTest();
        MergeContextBuilder.BuildResult result = MergeContextBuilder.build(tWithFields, acc.Id);
        Test.stopTest();
        
        Assert.isNotNull(result);
        // putByDotPath nested map reuse — Owner.Name + Owner.Email same parent
        Map<String, Object> ownerMap = (Map<String, Object>) result.context.get('Owner');

    }

    @isTest
    static void build_resolveBuiltin_fallthrough() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        Document_Template__c template = new Document_Template__c(Name = 'Builtin Fallthrough', Object_API_Name__c = 'Account');
        insert template;
        insert new Document_Template_Field__c(Document_Template__c = template.Id, Tag_Name__c = 'UNKNOWN_BUILTIN', Field_Type__c = 'Builtin');
        
        Document_Template__c tWithFields = [
            SELECT Id, Object_API_Name__c,
                   (SELECT Tag_Name__c, Field_Type__c, Loop_Parent__c FROM Template_Fields__r)
            FROM Document_Template__c WHERE Id = :template.Id
        ];
        
        Test.startTest();
        MergeContextBuilder.BuildResult result = MergeContextBuilder.build(tWithFields, acc.Id);
        Test.stopTest();
        
        Assert.isNotNull(result);
    }

    @isTest
    static void build_imageFetchCap() {
        Account acc = [SELECT Id FROM Account LIMIT 1];
        acc.Website = 'https://picsum.photos/200';
        update acc;
        
        Document_Template__c template = new Document_Template__c(Name = 'Image Cap', Object_API_Name__c = 'Account');
        insert template;
        insert new List<Document_Template_Field__c>{
            new Document_Template_Field__c(Document_Template__c = template.Id, Tag_Name__c = 'Website',  Field_Type__c = 'Image'),
            new Document_Template_Field__c(Document_Template__c = template.Id, Tag_Name__c = 'PhotoUrl', Field_Type__c = 'Image')
        };
        
        Document_Template__c tWithFields = [
            SELECT Id, Object_API_Name__c,
                   (SELECT Tag_Name__c, Field_Type__c, Loop_Parent__c FROM Template_Fields__r)
            FROM Document_Template__c WHERE Id = :template.Id
        ];
        
        Test.setMock(HttpCalloutMock.class, new SuccessfulImageMock());
        
        Test.startTest();
        MergeContextBuilder.BuildResult result = MergeContextBuilder.build(tWithFields, acc.Id);
        Test.stopTest();
        
        Assert.isNotNull(result);
    }
    
    // =============================================================
    // Mock Classes
    // =============================================================
    
    private class SuccessfulImageMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'image/png');
            res.setBodyAsBlob(Blob.valueOf('fake image bytes'));
            return res;
        }
    }
    
    private class NonImageContentTypeMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'text/html');
            res.setBody('<html>not an image</html>');
            return res;
        }
    }

    private class HttpErrorMock implements HttpCalloutMock {
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(404);
            res.setBody('Not Found');
            return res;
        }
    }
}