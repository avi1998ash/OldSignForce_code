@IsTest
private class AgentforceListTemplatesTest {

    @IsTest
    static void testListTemplatesCoverage() {

        AgentforceListTemplates.Request req1 =
            new AgentforceListTemplates.Request();
        req1.objectApiName = 'Account';

        AgentforceListTemplates.Request req2 =
            new AgentforceListTemplates.Request();
        req2.objectApiName = null;

        AgentforceListTemplates.Request req3 =
            new AgentforceListTemplates.Request();
        req3.objectApiName = 'Opportunity';

        AgentforceListTemplates.Request req4 = null;

        Test.startTest();

        List<AgentforceListTemplates.Response> responses =
            AgentforceListTemplates.getInvocableActions(
                new List<AgentforceListTemplates.Request>{
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
            'Agentforce is disabled in this build, so listing templates for an object returns the disabled message instead of querying templates.');
        Assert.areEqual(
            AgentforceActionsLwc.DISABLED_MESSAGE,
            responses[1].result,
            'A null object API name takes the same disabled path rather than falling back to an unfiltered query.');
        Assert.areEqual(false, responses[3].success,
            'A null request cannot be read and must be reported as a failed response, not silently skipped.');
    }

    @IsTest
    static void testEmptyRequestList() {

        Test.startTest();

        List<AgentforceListTemplates.Response> responses =
            AgentforceListTemplates.getInvocableActions(
                new List<AgentforceListTemplates.Request>()
            );

        Test.stopTest();

        Assert.areEqual(0, responses.size(),
            'An empty request batch must produce an empty response list, never a null or a placeholder response.');
    }
}