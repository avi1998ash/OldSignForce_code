/**
 * LegacyStampingCoverageTest — covers StampedPDFController (the Visualforce
 * client-side stamper constructor + saveStampedPDF RemoteAction).
 *
 * Previously also covered GenerateStampedPDFQueueable. That class has been
 * retired (body commented out — it had no production caller and was superseded
 * by AgreementController.generateStampedPDFServerAsync), so its two tests were
 * removed with it. StampedPDFController is still live and keeps its coverage.
 */
@isTest(SeeAllData=false)
private class LegacyStampingCoverageTest {

    @isTest
    static void stampedPdfController_constructorBuildsFieldsJson() {
        Agreement__c agr = TestDataFactory.createSentAgreement('VF Stamper');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'vf@example.com');
        TestDataFactory.createTier1OriginalDoc(agr.Id); // Original + ContentVersion
        Signature_Field__c f = TestDataFactory.createSignatureField(agr.Id, signer.Id, 1, 100, 200);
        f.Field_Value__c = 'John';
        f.Is_Completed__c = true;
        update f;

        Test.startTest();
        ApexPages.currentPage().getParameters().put('agreementId', agr.Id);
        StampedPDFController ctrl = new StampedPDFController();
        Test.stopTest();

        System.assertEquals(String.valueOf(agr.Id), ctrl.agreementId);
        System.assertNotEquals(null, ctrl.pdfBase64, 'Original bytes read as base64');
        System.assert(ctrl.fieldsJson != null && ctrl.fieldsJson.startsWith('['),
            'Fields serialized to JSON: ' + ctrl.fieldsJson);
    }

    @isTest
    static void stampedPdfController_constructorNoIdIsSafe() {
        Test.startTest();
        StampedPDFController ctrl = new StampedPDFController(); // no agreementId param
        Test.stopTest();
        System.assertEquals(null, ctrl.agreementId, 'Blank id short-circuits the constructor');
    }

    @isTest
    static void saveStampedPDF_insertsStampedDoc() {
        Agreement__c agr = TestDataFactory.createSentAgreement('VF Save');
        String b64 = EncodingUtil.base64Encode(Blob.valueOf('%PDF-1.4 stamped bytes'));

        Test.startTest();
        String result = StampedPDFController.saveStampedPDF(agr.Id, b64);
        Test.stopTest();

        System.assertEquals('OK', result, 'Save should return OK');
        List<Agreement_Document__c> stamped = [
            SELECT Content_Version_ID__c FROM Agreement_Document__c
            WHERE Agreement__c = :agr.Id AND Document_Type__c = 'Stamped'
        ];
        System.assertEquals(1, stamped.size(), 'Stamped doc created');
        System.assertNotEquals(null, stamped[0].Content_Version_ID__c);
    }

    @isTest
    static void saveStampedPDF_replacesPriorStamped() {
        Agreement__c agr = TestDataFactory.createSentAgreement('VF Resave');
        String b64 = EncodingUtil.base64Encode(Blob.valueOf('pdf-one'));
        StampedPDFController.saveStampedPDF(agr.Id, b64);
        // Second save replaces the first, not duplicates it.
        StampedPDFController.saveStampedPDF(agr.Id, EncodingUtil.base64Encode(Blob.valueOf('pdf-two')));

        Integer count = [
            SELECT COUNT() FROM Agreement_Document__c
            WHERE Agreement__c = :agr.Id AND Document_Type__c = 'Stamped'
        ];
        System.assertEquals(1, count, 'Prior Stamped replaced, not duplicated');
    }

    @isTest
    static void saveStampedPDF_badIdReturnsError() {
        Test.startTest();
        String result = StampedPDFController.saveStampedPDF('a00000000000000AAA', 'UERG');
        Test.stopTest();
        System.assert(result != null && result.startsWith('ERROR'),
            'Invalid agreement id should return an ERROR string, got: ' + result);
    }
}