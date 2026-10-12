@IsTest
private class AgentforceListPendingTest {

    @IsTest
    static void testListPendingCoverage() {

        AgentforceListPending.Request req1 =
            new AgentforceListPending.Request();

        req1.maxResults = 10;

        AgentforceListPending.Request req2 =
            new AgentforceListPending.Request();

        req2.maxResults = -1;

        AgentforceListPending.Request req3 =
            new AgentforceListPending.Request();

        req3.maxResults = null;

        AgentforceListPending.Request req4 = null;

        Test.startTest();

        List<AgentforceListPending.Response> results =
        AgentforceListPending.getInvocableActions(
            new List<AgentforceListPending.Request>{
                req1,
                req2,
                req3,
                req4
            }
        );

        Test.stopTest();

        Assert.areEqual(4, results.size(),
            'One response must come back per request, including the null request');
        Assert.areEqual(AgentforceActionsLwc.DISABLED_MESSAGE, results[0].result,
            'Agentforce is disabled, so a bounded request must return the disabled message');
        Assert.areEqual(AgentforceActionsLwc.DISABLED_MESSAGE, results[2].result,
            'A null maxResults must return the disabled message too, not throw');
        Assert.areEqual(false, results[3].success,
            'A null request must be reported as a failure rather than silently succeeding');
    }
}