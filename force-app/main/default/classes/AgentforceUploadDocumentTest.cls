@IsTest
private class AgentforceUploadDocumentTest {

    @IsTest
    static void testUploadDocumentCoverage() {

        Agreement__c agr = new Agreement__c(
            Name = 'Test Agreement'
        );
        insert agr;

        AgentforceUploadDocument.Request successReq =
            new AgentforceUploadDocument.Request();

        successReq.agreementId = agr.Id;
        successReq.fileName = 'Test.pdf';
        successReq.pdfBase64 =
            EncodingUtil.base64Encode(
                Blob.valueOf('Test PDF Content')
            );
        successReq.fileSize = 100;

        AgentforceUploadDocument.Request failureReq =
            new AgentforceUploadDocument.Request();

        failureReq.agreementId = 'INVALID_ID';
        failureReq.fileName = 'Bad.pdf';
        failureReq.pdfBase64 = 'BAD_BASE64';

        AgentforceUploadDocument.Request nullReq = null;

        Test.startTest();

        List<AgentforceUploadDocument.Response> responses =
            AgentforceUploadDocument.getInvocableActions(
                new List<AgentforceUploadDocument.Request>{
                    successReq,
                    failureReq,
                    nullReq
                }
            );

        Test.stopTest();

        Assert.areEqual(3, responses.size(),
            'The wrapper must return one response per request, including the null one.');
        Assert.areEqual(
            AgentforceActionsLwc.DISABLED_MESSAGE,
            responses[0].result,
            'Agentforce is disabled in this build, so a well-formed upload returns the disabled message instead of an uploaded-document confirmation.');
        Assert.isNull(responses[0].recordId,
            'No document record is created while the action is disabled, so the response must carry no record Id.');
        Assert.areEqual(false, responses[2].success,
            'A null request cannot be read and must be reported as a failed response, not silently skipped.');
    }

    @IsTest
    static void testEmptyRequestList() {

        List<AgentforceUploadDocument.Response> responses =
            AgentforceUploadDocument.getInvocableActions(
                new List<AgentforceUploadDocument.Request>()
            );

        Assert.areEqual(0, responses.size(),
            'An empty request batch must produce an empty response list, never a null or a placeholder response.');
    }
}