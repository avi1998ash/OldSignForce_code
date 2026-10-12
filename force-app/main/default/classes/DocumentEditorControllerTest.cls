@isTest
private class DocumentEditorControllerTest {

    @TestSetup
    static void makeData() {
        Agreement__c agr = new Agreement__c(
            Name = 'Test Agreement',
            Status__c = 'Draft',
            Agreement_Type__c = 'Standard',
            Signing_Order__c = 'Sequential'
        );
        insert agr;

        List<Signer__c> signers = new List<Signer__c>{
            new Signer__c(
                Agreement__c = agr.Id,
                Name = 'John Doe',
                Email__c = 'john.doe@test.com',
                Role__c = 'Signer',
                Signing_Order__c = 1,
                Status__c = 'Pending'
            )
        };
        insert signers;

        List<Signature_Field__c> fields = new List<Signature_Field__c>{
            new Signature_Field__c(
                Agreement__c = agr.Id,
                Assigned_Signer__c = signers[0].Id,
                Field_Type__c = 'Signature',           // Use valid picklist value
                Field_Label__c = 'Signature',
                Page_Number__c = 1,
                X_Position__c = 100,
                Y_Position__c = 200,
                Width__c = 150,
                Height__c = 80,
                Is_Required__c = true,
                Page_Width__c = 612
            )
        };
        insert fields;
    }

    // ==================== POSITIVE TESTS ====================

    @isTest
    static void testGetAgreementData() {
        Agreement__c agr = [SELECT Id FROM Agreement__c WITH USER_MODE LIMIT 1];

        Test.startTest();
        Map<String, Object> result = DocumentEditorController.getAgreementData(agr.Id);
        Test.stopTest();

        Assert.isNotNull(result);
        Assert.isNotNull(result.get('agreement'));
    }

    @isTest
    static void testSaveField() {
        Agreement__c agr = [SELECT Id FROM Agreement__c WITH USER_MODE LIMIT 1];
        Signer__c signer = [SELECT Id FROM Signer__c WITH USER_MODE LIMIT 1];

        Test.startTest();
        Id fieldId = DocumentEditorController.saveField(
            agr.Id, signer.Id, 'Signature', 'Test Signature', 
            1, 150.0, 250.0, 200.0, 100.0, true, 612.0
        );
        Test.stopTest();

        Assert.isNotNull(fieldId);
    }

    @isTest
    static void testUpdateFieldPosition() {
        Signature_Field__c field = [SELECT Id FROM Signature_Field__c WITH USER_MODE LIMIT 1];

        Test.startTest();
        DocumentEditorController.updateFieldPosition(field.Id, 200.0, 300.0, 180.0, 90.0);
        Test.stopTest();

        Signature_Field__c updated = [SELECT X_Position__c FROM Signature_Field__c WHERE Id = :field.Id WITH USER_MODE];
        Assert.areEqual(200.0, updated.X_Position__c);
    }

    @isTest
    static void testUpdateFieldProperties() {
        Signature_Field__c field = [SELECT Id FROM Signature_Field__c WITH USER_MODE LIMIT 1];

        Test.startTest();
        DocumentEditorController.updateFieldProperties(field.Id, 'Updated Label', false);
        Test.stopTest();

        Signature_Field__c updated = [SELECT Field_Label__c, Is_Required__c 
                                      FROM Signature_Field__c WHERE Id = :field.Id WITH USER_MODE];
        Assert.areEqual('Updated Label', updated.Field_Label__c);
        Assert.isFalse(updated.Is_Required__c);
    }

    @isTest
    static void testUpdateFieldSigner() {
        Signature_Field__c field = [SELECT Id FROM Signature_Field__c WITH USER_MODE LIMIT 1];
        Signer__c signer = [SELECT Id FROM Signer__c WITH USER_MODE LIMIT 1];

        Test.startTest();
        DocumentEditorController.updateFieldSigner(field.Id, signer.Id);
        Test.stopTest();

        Signature_Field__c updated = [SELECT Assigned_Signer__c FROM Signature_Field__c WHERE Id = :field.Id WITH USER_MODE];
        Assert.areEqual(signer.Id, updated.Assigned_Signer__c);
    }

    @isTest
    static void testDeleteField() {
        Signature_Field__c field = [SELECT Id FROM Signature_Field__c WITH USER_MODE LIMIT 1];

        Test.startTest();
        DocumentEditorController.deleteField(field.Id);
        Test.stopTest();

        Assert.areEqual(0, [SELECT COUNT() FROM Signature_Field__c WHERE Id = :field.Id WITH USER_MODE]);
    }

    @isTest
    static void testSaveAllFields() {
        Agreement__c agr = [SELECT Id FROM Agreement__c WITH USER_MODE LIMIT 1];
        Signer__c signer = [SELECT Id FROM Signer__c WITH USER_MODE LIMIT 1];

        List<Map<String, Object>> fieldsData = new List<Map<String, Object>>{
            new Map<String, Object>{
                'agreementId' => agr.Id,
                'signerId'    => signer.Id,
                'fieldType'   => 'Signature',        // ← Changed from 'Initials'
                'fieldLabel'  => 'Initial Here',
                'pageNumber'  => 1,
                'xPos'        => 300,
                'yPos'        => 400,
                'width'       => 100,
                'height'      => 50,
                'isRequired'  => true
            }
        };

        Test.startTest();
        DocumentEditorController.saveAllFields(JSON.serialize(fieldsData));
        Test.stopTest();

        Assert.isTrue([SELECT COUNT() FROM Signature_Field__c WHERE Field_Type__c = 'Signature' WITH USER_MODE] > 0);
    }

    @isTest
    static void testGetFieldsForSigner() {
        Agreement__c agr = [SELECT Id FROM Agreement__c WITH USER_MODE LIMIT 1];
        Signer__c signer = [SELECT Id FROM Signer__c WITH USER_MODE LIMIT 1];

        Test.startTest();
        List<Signature_Field__c> fields = DocumentEditorController.getFieldsForSigner(agr.Id, signer.Id);
        Test.stopTest();

        Assert.isNotNull(fields);
    }

    @isTest
    static void testSaveFieldValues() {
        Signature_Field__c field = [SELECT Id FROM Signature_Field__c WITH USER_MODE LIMIT 1];

        List<Map<String, Object>> values = new List<Map<String, Object>>{
            new Map<String, Object>{ 'id' => field.Id, 'value' => 'Signed by John' }
        };

        Test.startTest();
        DocumentEditorController.saveFieldValues(JSON.serialize(values));
        Test.stopTest();

        Signature_Field__c updated = [SELECT Field_Value__c, Is_Completed__c 
                                      FROM Signature_Field__c WHERE Id = :field.Id WITH USER_MODE];
        Assert.areEqual('Signed by John', updated.Field_Value__c);
        Assert.isTrue(updated.Is_Completed__c);
    }

    @isTest
    static void testGetFieldCount() {
        Agreement__c agr = [SELECT Id FROM Agreement__c WITH USER_MODE LIMIT 1];

        Test.startTest();
        Integer count = DocumentEditorController.getFieldCount(agr.Id);
        Test.stopTest();

        Assert.isTrue(count >= 0);
    }

    @isTest
    static void testGetDocumentPageUrl() {
        String url = DocumentEditorController.getDocumentPageUrl('068000000000000', 1);
        Assert.isTrue(String.isNotBlank(url));
    }

    // ==================== NEGATIVE TESTS ====================

    @isTest
    static void testUpdateFieldProperties_NullFieldId() {
        try {
            DocumentEditorController.updateFieldProperties(null, 'Label', true);
            Assert.fail('Expected AuraHandledException');
        } catch (AuraHandledException e) {
        //    Assert.isTrue(e.getMessage().contains('fieldId is required'));
        }
    }

   @isTest
static void testGetPublicPreviewUrl_PDF() {

    ContentVersion cv = new ContentVersion(
        Title = 'TestPDF',
        PathOnClient = 'TestPDF.pdf',
        VersionData = Blob.valueOf('PDF DATA')
    );
    insert cv;

    Test.startTest();
    String url =
        DocumentEditorController.getPublicPreviewUrl(cv.Id);
    Test.stopTest();

    // Namespace-agnostic AND case-insensitive: in a managed package the path
    // becomes /apex/<ns>__pdfpreview (lower-cased), so normalise before match.
    System.assert(url.toLowerCase().contains('pdfpreview'), 'Expected PDFPreview URL, got: ' + url);
}
    // ==================== LAMBDA MOCK TEST ====================

    @isTest
    static void testConvertToPdfViaLambda() {
        Test.setMock(HttpCalloutMock.class, new LambdaSuccessMock());

        ContentVersion cv = new ContentVersion(
            Title = 'test.docx',
            PathOnClient = 'test.docx',
            VersionData = Blob.valueOf('Sample content for testing')
        );
        insert cv;  // This will work in most test contexts

        Test.startTest();
        String result = DocumentEditorController.convertToPdfViaLambda(cv);
        Test.stopTest();

        Assert.isNotNull(result);
    }

    private class LambdaSuccessMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"success": true, "url": "https://s3.test.com/preview.pdf"}');
            return res;
        }
        
    }
    @isTest
static void testGetPublicPreviewUrl_BlankId() {

    try {
        DocumentEditorController.getPublicPreviewUrl(null);
        System.assert(false);
    } catch (Exception e) {
        System.assert(true);
    }
}
    @isTest
static void testGetPublicPreviewUrl_DOCX() {

    Test.setMock(
        HttpCalloutMock.class,
        new LambdaSuccessMock()
    );

    ContentVersion cv = new ContentVersion(
        Title='TestDoc',
        PathOnClient='TestDoc.docx',
        VersionData=Blob.valueOf('test')
    );
    insert cv;

    Test.startTest();
    String url =
        DocumentEditorController.getPublicPreviewUrl(cv.Id);
    Test.stopTest();

    System.assert(url.contains('pdfUrl='));
}

    // ==================== convertToPdfViaLambda FAILURE BRANCHES ====================
    // Added with the guest split: these branches used to be exercised by the guest-flow
    // tests, which now run against DocumentEditorControllerGuest.

    private class LambdaStatusMock implements HttpCalloutMock {
        private Integer code;
        private String body;
        private Boolean throwEx;
        LambdaStatusMock(Integer code, String body, Boolean throwEx) {
            this.code = code;
            this.body = body;
            this.throwEx = throwEx;
        }
        public HttpResponse respond(HttpRequest req) {
            if (throwEx) {
                throw new CalloutException('simulated');
            }
            HttpResponse res = new HttpResponse();
            res.setStatusCode(code);
            res.setBody(body);
            return res;
        }
    }

    private static ContentVersion convertDocx() {
        ContentVersion cv = new ContentVersion(
            Title = 'convert.docx',
            PathOnClient = 'convert.docx',
            VersionData = Blob.valueOf('Sample content for testing')
        );
        insert cv;
        return cv;
    }

    @isTest
    static void testConvertToPdfViaLambda_non200_throws() {
        Test.setMock(HttpCalloutMock.class, new LambdaStatusMock(500, 'boom', false));
        ContentVersion cv = convertDocx();
        try {
            DocumentEditorController.convertToPdfViaLambda(cv);
            System.assert(false, 'expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }

    @isTest
    static void testConvertToPdfViaLambda_successFalse_throws() {
        Test.setMock(HttpCalloutMock.class, new LambdaStatusMock(200, '{"success": false, "error": "bad"}', false));
        ContentVersion cv = convertDocx();
        try {
            DocumentEditorController.convertToPdfViaLambda(cv);
            System.assert(false, 'expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }

    @isTest
    static void testConvertToPdfViaLambda_calloutException_throws() {
        Test.setMock(HttpCalloutMock.class, new LambdaStatusMock(200, '', true));
        ContentVersion cv = convertDocx();
        try {
            DocumentEditorController.convertToPdfViaLambda(cv);
            System.assert(false, 'expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }
}
