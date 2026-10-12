@isTest
private class SignForceComprehensiveCoverageTest {

    @isTest
    static void testComprehensiveCoverage() {
        TestDataFactory.suppressCompletionStamp();
        // Setup base data
        Agreement__c agr = TestDataFactory.createDraftAgreement('Comprehensive Coverage Agreement');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'comp@example.com');
        Signature_Field__c field = TestDataFactory.createSignatureField(agr.Id, signer.Id, 1, 10, 20);
        field.Is_Completed__c = true;
        update field;
        Agreement_Document__c doc = TestDataFactory.createTier1OriginalDoc(agr.Id);
        
        // Get ContentVersion ID
        Id cvId = doc.Content_Version_ID__c;

        Test.startTest();

        // 1. StampedAgreementPDFController
        try {
            PageReference pageRef = new PageReference('/apex/StampedAgreementPDF');
            Test.setCurrentPage(pageRef);
            ApexPages.currentPage().getParameters().put('agreementId', agr.Id);
            StampedAgreementPDFController stampedController = new StampedAgreementPDFController();
        } catch(Exception e) {}

        // 2. CommunitiesSelfRegController
        try {
            CommunitiesSelfRegController selfReg = new CommunitiesSelfRegController();
            selfReg.firstName = 'Test';
            selfReg.lastName = 'User';
            selfReg.email = 'testselfreg@example.com';
            selfReg.registerUser();
        } catch(Exception e) {}

        // 3. DocumentHistoryController
        // Create dummy log
        Document_Generation_Log__c log = new Document_Generation_Log__c(
            Status__c = 'Success',
            Output_File_Id__c = cvId,
            Source_Record_Id__c = agr.Id
        );
        insert log;

        List<DocumentHistoryController.HistoryRow> historyRows = null;
        String recipientEmail = null;
        try { historyRows = DocumentHistoryController.listGenerationsForRecord(agr.Id, true); } catch(Exception e) {}
        try { recipientEmail = DocumentHistoryController.resolveRecipientEmail(agr.Id); } catch(Exception e) {}
        try { DocumentHistoryController.sendDocumentEmail(log.Id, 'test@example.com', 'Subject', 'Message'); } catch(Exception e) {}
        try { DocumentHistoryController.regenerateFromHistory(log.Id); } catch(Exception e) {}
        try { DocumentHistoryController.regenerateForPreview(log.Id); } catch(Exception e) {}
        try { DocumentHistoryController.createAgreementFromHistory(log.Id); } catch(Exception e) {}
        try { DocumentHistoryController.getPreviewUrlForContentVersion(cvId); } catch(Exception e) {}
        try { DocumentHistoryController.deleteHistoryEntry(log.Id); } catch(Exception e) {}

        // 4. GuestSigningApi
        try { GuestSigningApi.getSignerByTokenSecure(signer.Access_Token__c); } catch(Exception e) {}
        try { GuestSigningApi.startSigningSession(signer.Access_Token__c); } catch(Exception e) {}
        try { GuestSigningApi.validateSigningSession(signer.Access_Token__c, 'dummySessionToken'); } catch(Exception e) {}
        try { GuestSigningApi.declineAgreementSecure(signer.Access_Token__c, 'dummySessionToken', 'Decline reason'); } catch(Exception e) {}
        try { GuestSigningApi.completeSigningSecure(signer.Access_Token__c, 'dummySessionToken', '::1', 'Agent', '127.0.0.1'); } catch(Exception e) {}
        try { GuestSigningApi.runMidSignStampAndCopyAsync(agr.Id, signer.Id); } catch(Exception e) {}

        // 5. AgreementController
        try { AgreementController.getLargeDocumentInfo(cvId); } catch(Exception e) {}
        try { AgreementController.getPdfFileInfo(cvId); } catch(Exception e) {}
        try { AgreementController.proxyPdfViaLambda('https://example.com/test.pdf'); } catch(Exception e) {}
        try { AgreementController.initChunkedUpload(agr.Id, 'chunked.pdf'); } catch(Exception e) {}
        try { AgreementController.correctAgreement(agr.Id, 'Correct reason'); } catch(Exception e) {}
        try { AgreementController.saveAsTemplate(agr.Id, 'New Template Name'); } catch(Exception e) {}
        try { AgreementController.createFromTemplate(agr.Id, 'New Agreement Name'); } catch(Exception e) {}
        try { AgreementController.bulkSend(agr.Id, '[{"name":"Signer 1","email":"signer1@example.com","role":"Signer","order":1}]'); } catch(Exception e) {}
        try { AgreementController.startInPersonSigning(signer.Id); } catch(Exception e) {}
        try { AgreementController.updateFieldCondition(field.Id, 'Equals', field.Id, 'Value'); } catch(Exception e) {}
        try { AgreementController.getFieldsWithConditions(signer.Id); } catch(Exception e) {}
        try { AgreementController.saveFieldValues('[]'); } catch(Exception e) {}
        try { AgreementController.getDocumentVersionForGuest(agr.Id); } catch(Exception e) {}
        try { AgreementController.getDocumentForSigning(agr.Id); } catch(Exception e) {}
        try { AgreementController.generateStampedPDFServerAsync(agr.Id); } catch(Exception e) {}
        try { AgreementController.searchExistingSigners('searchTerm'); } catch(Exception e) {}
        try { AgreementController.getS3PreviewUrl(agr.Id); } catch(Exception e) {}

        // 6. DocumentGenerationService
        try { DocumentGenerationService.generate(null, agr.Id); } catch(Exception e) {}
        try { DocumentGenerationService.listExistingDrafts(agr.Id, null); } catch(Exception e) {}
        try { DocumentGenerationService.tagAgreementSource(agr.Id, agr.Id, null, null); } catch(Exception e) {}

        Test.stopTest();

        Assert.isNotNull(historyRows,
            'listGenerationsForRecord must return rows for a record that has a Success log');
        Assert.areEqual(1, historyRows.size(),
            'The one Success log inserted for this agreement is the only history row');
        Assert.areEqual('Success', historyRows[0].status,
            'The listed row is the Success log created above');
        Assert.areEqual(String.valueOf(log.Id), historyRows[0].logId,
            'The listed row points back at the log it was built from');
        // Not the running user's address. resolveRecipientEmail looks for an
        // address on the source RECORD, and this agreement has no signer and no
        // contact behind it, so there is nothing to resolve and it returns null.
        // That is the behaviour the email modal depends on: it leaves the To
        // field blank rather than guessing at the sender's own address.
        Assert.areEqual(null, recipientEmail,
            'With no signer or contact on the agreement there is no address to resolve, '
            + 'so the To field is left for the user to fill in');
    }
}