@IsTest
private class AgentforceCreateAgreementTest {

    @IsTest
    static void testCreateAgreementCoverage() {

        AgentforceCreateAgreement.Request req1 =
            new AgentforceCreateAgreement.Request();
        req1.name = 'Test Agreement';
        req1.agreementType = 'NDA';
        req1.signingOrder = 'Parallel';
        req1.message = 'Test Message';
        req1.expiryDate = Date.today().addDays(30);

        AgentforceCreateAgreement.Request req2 =
            new AgentforceCreateAgreement.Request();
        req2.name = 'Agreement Two';

        AgentforceCreateAgreement.Request req3 =
            new AgentforceCreateAgreement.Request();
        req3.name = null;

        AgentforceCreateAgreement.Request req4 = null;

        Test.startTest();

        List<AgentforceCreateAgreement.Response> responses =
            AgentforceCreateAgreement.getInvocableActions(
                new List<AgentforceCreateAgreement.Request>{
                    req1,
                    req2,
                    req3,
                    req4
                }
            );

        Test.stopTest();

        Assert.areEqual(4, responses.size(),
            'Every entry in the request list, including the null one, must produce a response.');
        Assert.areEqual(
            AgentforceActionsLwc.DISABLED_MESSAGE,
            responses[0].result,
            'Agentforce is disabled in this build, so no agreement is created and the disabled message is returned.');
        Assert.isFalse(responses[3].success,
            'The null request is caught by the wrapper and reported as a failed response rather than thrown.');
    }

    @IsTest
    static void testEmptyRequestList() {

        Test.startTest();

        List<AgentforceCreateAgreement.Response> responses =
            AgentforceCreateAgreement.getInvocableActions(
                new List<AgentforceCreateAgreement.Request>()
            );

        Test.stopTest();

        Assert.areEqual(0, responses.size(),
            'An empty request list must produce no responses at all.');
    }
}