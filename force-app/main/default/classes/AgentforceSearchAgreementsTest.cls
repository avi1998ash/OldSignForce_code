@IsTest
private class AgentforceSearchAgreementsTest {

    @IsTest
    static void testSearchAgreementsCoverage() {

        AgentforceSearchAgreements.Request req1 =
            new AgentforceSearchAgreements.Request();
        req1.searchTerm = 'Test';
        req1.maxResults = 10;

        AgentforceSearchAgreements.Request req2 =
            new AgentforceSearchAgreements.Request();
        req2.searchTerm = '';
        req2.maxResults = 5;

        AgentforceSearchAgreements.Request req3 =
            new AgentforceSearchAgreements.Request();
        req3.searchTerm = 'Agreement';
        req3.maxResults = null;

        AgentforceSearchAgreements.Request req4 = null;

        Test.startTest();

        List<AgentforceSearchAgreements.Response> responses =
            AgentforceSearchAgreements.getInvocableActions(
                new List<AgentforceSearchAgreements.Request>{
                    req1,
                    req2,
                    req3,
                    req4
                }
            );

        Test.stopTest();

        Assert.areEqual(4, responses.size(),
            'The wrapper must return one response per request, including the null one.');
        Assert.areEqual(
            AgentforceActionsLwc.DISABLED_MESSAGE,
            responses[0].result,
            'Agentforce is disabled in this build, so a search returns the disabled message instead of running the agreement query.');
        Assert.areEqual(
            AgentforceActionsLwc.DISABLED_MESSAGE,
            responses[1].result,
            'A blank search term takes the same disabled path rather than reaching the search implementation.');
        Assert.areEqual(false, responses[3].success,
            'A null request cannot be read and must be reported as a failed response, not silently skipped.');
    }

    @IsTest
    static void testEmptyRequestList() {

        Test.startTest();

        List<AgentforceSearchAgreements.Response> responses =
            AgentforceSearchAgreements.getInvocableActions(
                new List<AgentforceSearchAgreements.Request>()
            );

        Test.stopTest();

        Assert.areEqual(0, responses.size(),
            'An empty request batch must produce an empty response list, never a null or a placeholder response.');
    }
}