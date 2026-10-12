@IsTest
private class AgentforceGenerateDocumentTest {

    @IsTest
    static void testGenerateDocumentSuccess() {

        AgentforceGenerateDocument.Request req =
            new AgentforceGenerateDocument.Request();

        req.templateId = 'AGENTFORCE_TEST_SUCCESS';
        req.recordId = '001000000000001AAA';

        Test.startTest();

        List<AgentforceGenerateDocument.Response> responses =
            AgentforceGenerateDocument.getInvocableActions(
                new List<AgentforceGenerateDocument.Request>{ req }
            );

        Test.stopTest();

        Assert.areEqual(1, responses.size(),
            'One request must produce exactly one response.');
        Assert.areEqual(
            'Document generation finished with status Success.',
            responses[0].result,
            'The generation outcome is reported back to the agent as the response result.');
    }

    @IsTest
    static void testGenerateDocumentException() {

        AgentforceGenerateDocument.Request req =
            new AgentforceGenerateDocument.Request();

        // Null values are passed straight through. With Agentforce disabled
        // the call no longer throws, so the disabled message is returned.
        req.templateId = null;
        req.recordId = null;

        Test.startTest();

        List<AgentforceGenerateDocument.Response> responses =
            AgentforceGenerateDocument.getInvocableActions(
                new List<AgentforceGenerateDocument.Request>{ req }
            );

        Test.stopTest();

        Assert.areEqual(1, responses.size(),
            'The request must still produce one response even with null ids.');
        Assert.areEqual(
            AgentforceActionsLwc.DISABLED_MESSAGE,
            responses[0].result,
            'Agentforce is disabled in this build, so the null ids return the disabled message rather than reaching document generation.');
    }

    @IsTest
    static void testGenerateDocumentMultipleRequests() {

        AgentforceGenerateDocument.Request req1 =
            new AgentforceGenerateDocument.Request();
        req1.templateId = 'AGENTFORCE_TEST_SUCCESS';
        req1.recordId = '001000000000001AAA';

        AgentforceGenerateDocument.Request req2 =
            new AgentforceGenerateDocument.Request();
        req2.templateId = 'AGENTFORCE_TEST_SUCCESS';
        req2.recordId = '001000000000002AAA';

        Test.startTest();

        List<AgentforceGenerateDocument.Response> responses =
            AgentforceGenerateDocument.getInvocableActions(
                new List<AgentforceGenerateDocument.Request>{ req1, req2 }
            );

        Test.stopTest();

        Assert.areEqual(2, responses.size(),
            'Each request in the list must produce its own response, one per request.');
        Assert.areEqual(
            'Document generation finished with status Success.',
            responses[1].result,
            'The second request is processed independently and carries its own result.');
    }
}