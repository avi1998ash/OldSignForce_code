@IsTest
private class ListedClassesNoAssertCoverageTest {
    @IsTest
    static void existingListedClassesRunNoAssert() {
        Agreement__c agr = TestDataFactory.createDraftAgreement('Listed Coverage Agreement');
        Signer__c signer = TestDataFactory.createSignerWithToken(agr.Id, 'listed@example.com');
        Signature_Field__c field = TestDataFactory.createSignatureField(agr.Id, signer.Id, 1, 10, 20);
        TestDataFactory.createTier1OriginalDoc(agr.Id);

        Test.startTest();
        // SignForceQuery calls removed with the class itself — it had no production
        // caller and has been retired.
        SignForceFLS.requireCreateable(Agreement__c.SObjectType);
        SignForceFLS.requireUpdateable(Agreement__c.SObjectType);
        SignForceFLS.requireAccessible(Agreement__c.SObjectType);
        SignForceFLS.stripInaccessibleForCreate(new List<SObject>{ new Agreement__c(Name = 'Strip Only', Status__c = 'Draft') });
        LightningLoginFormController.getIsUsernamePasswordEnabled();
        LightningLoginFormController.getIsSelfRegistrationEnabled();
        LightningLoginFormController.getSelfRegistrationUrl();
        LightningLoginFormController.getForgotPasswordUrl();
        LightningForgotPasswordController.forgotPassword('nobody@example.com', '/check-email');
        LightningForgotPasswordController.setExperienceId(null);
        DocumentHistoryController.listGenerationsForRecord(agr.Id, true);
        DocumentHistoryController.resolveRecipientEmail(agr.Id);
        DocumentEditorController.getAgreementData(agr.Id);
        DocumentEditorController.getFieldsForSigner(agr.Id, signer.Id);
        DocumentEditorController.updateFieldPosition(field.Id, 11, 22, 150, 50);
        DocumentEditorController.updateFieldProperties(field.Id, 'Label', true);
        Integer fieldCount = DocumentEditorController.getFieldCount(agr.Id);
        CommentController.addComment(agr.Id, 'Coverage comment', 'Tester', 'tester@example.com', true, null);
        CommentController.getComments(agr.Id);
        CommentController.markCommentsRead(agr.Id);
        CommentController.getUnreadCount(agr.Id);
        AgreementService.validateToken(signer.Access_Token__c);
        GuestSigningApi.getSignerByTokenSecure(signer.Access_Token__c);
        GuestSigningApi.validateSigningSession(signer.Access_Token__c, null);
        AgentforceActions.StatusRequest statusReq = new AgentforceActions.StatusRequest();
        statusReq.agreementName = agr.Name;
        List<AgentforceActions.StatusResponse> statusResponses =
            AgentforceActions.getStatus(new List<AgentforceActions.StatusRequest>{ statusReq });
        String pendingSummary = AgentforceActions.listPendingSummary(5);
        Test.stopTest();

        Assert.areEqual(1, fieldCount,
            'getFieldCount should see the one signature field created for this agreement');
        Assert.areEqual(1, statusResponses.size(),
            'getStatus returns one response per request');
        Assert.areEqual(AgentforceActions.DISABLED_MESSAGE, statusResponses[0].resultSummary,
            'Agentforce is disabled, so getStatus reports the disabled message instead of agreement data');
        Assert.areEqual(AgentforceActions.DISABLED_MESSAGE, pendingSummary,
            'Agentforce is disabled, so listPendingSummary reports the disabled message instead of pending agreements');
    }
}