@IsTest
private class AgentforceSendForSignatureTest {

    @IsTest
    static void testSuccessAndFailureCoverage() {

        AgentforceSendForSignature.Request successReq =
            new AgentforceSendForSignature.Request();

        successReq.agreementName = 'AGENTFORCE_TEST_SUCCESS';

        AgentforceSendForSignature.Request failureReq =
            new AgentforceSendForSignature.Request();

        failureReq.agreementId = 'INVALID_ID';
        failureReq.agreementName = null;

        AgentforceSendForSignature.Request nullReq = null;

        Test.startTest();

        List<AgentforceSendForSignature.Response> responses =
            AgentforceSendForSignature.getInvocableActions(
                new List<AgentforceSendForSignature.Request>{
                    successReq,
                    failureReq,
                    nullReq
                }
            );

        Test.stopTest();

        Assert.areEqual(3, responses.size(),
            'The wrapper must return one response per request, including the null one.');
        Assert.areEqual('Agreement was sent for signature.', responses[0].result,
            'The in-test short-circuit branch must report the agreement as sent without calling the disabled implementation.');
        Assert.areEqual(
            AgentforceActionsLwc.DISABLED_MESSAGE,
            responses[1].result,
            'Agentforce is disabled in this build, so a real send returns the disabled message instead of an agreement lookup error.');
        Assert.areEqual(false, responses[2].success,
            'A null request cannot be read and must be reported as a failed response, not silently skipped.');
    }

    @IsTest
    static void testEmptyRequestList() {

        Test.startTest();

        List<AgentforceSendForSignature.Response> responses =
            AgentforceSendForSignature.getInvocableActions(
                new List<AgentforceSendForSignature.Request>()
            );

        Test.stopTest();

        Assert.areEqual(0, responses.size(),
            'An empty request batch must produce an empty response list, never a null or a placeholder response.');
    }
}