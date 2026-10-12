@IsTest
private class AgentforceCreateAgreementActionTest {
    @IsTest
    static void invokeRunsNoAssert() {
        AgentforceCreateAgreementAction.Request validReq = new AgentforceCreateAgreementAction.Request();
        validReq.agreementName = 'Invocable Coverage Agreement';
        validReq.agreementType = 'NDA';
        validReq.signingOrder = 'Sequential';
        validReq.messageToSigners = 'Please sign';
        validReq.expiresInDays = 5;

        AgentforceCreateAgreementAction.Request badReq = new AgentforceCreateAgreementAction.Request();

        Test.startTest();
        List<AgentforceCreateAgreementAction.Response> responses =
            AgentforceCreateAgreementAction.invoke(new List<AgentforceCreateAgreementAction.Request>{ validReq, badReq, null });
        List<AgentforceCreateAgreementAction.Response> emptyResponses =
            AgentforceCreateAgreementAction.invoke(new List<AgentforceCreateAgreementAction.Request>());
        Test.stopTest();

        Assert.areEqual(3, responses.size(),
            'invoke must return exactly one response per request, including the null request');
        Assert.areEqual(0, emptyResponses.size(),
            'An empty request list must produce no responses');
        Assert.areNotEqual('I need a name for the agreement. What should I call it?', responses[0].message,
            'A request that supplies a name must get past validation');
        Assert.areEqual(false, responses[1].success,
            'A request with no agreement name must be reported as failed');
        Assert.areEqual('I need a name for the agreement. What should I call it?', responses[2].message,
            'A null request must be handled as a missing-name prompt, not an unhandled error');
    }
}