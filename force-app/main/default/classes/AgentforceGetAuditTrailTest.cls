@IsTest
private class AgentforceGetAuditTrailTest {

    @IsTest
    static void testSuccessPath() {

        Agreement__c agr = new Agreement__c(
            Name = 'Test Agreement'
        );
        insert agr;

        AgentforceGetAuditTrail.Request req =
            new AgentforceGetAuditTrail.Request();

        req.agreementId = agr.Id;
        req.maxResults = 10;

        Test.startTest();

        List<AgentforceGetAuditTrail.Response> responses =
            AgentforceGetAuditTrail.getInvocableActions(
                new List<AgentforceGetAuditTrail.Request>{ req }
            );

        Test.stopTest();

        Assert.areEqual(
            AgentforceActionsLwc.DISABLED_MESSAGE,
            responses[0].result,
            'Agentforce is disabled in this build, so the action returns the disabled message instead of querying signing events.');
        Assert.areEqual(String.valueOf(agr.Id), responses[0].recordId,
            'The wrapper echoes the requested agreement Id back on the response.');
    }

    @IsTest
    static void testFailurePath() {

        AgentforceGetAuditTrail.Request req =
            new AgentforceGetAuditTrail.Request();

        req.agreementId = 'INVALID_ID';
        req.agreementName = null;
        req.maxResults = 10;

        Test.startTest();

        List<AgentforceGetAuditTrail.Response> responses =
            AgentforceGetAuditTrail.getInvocableActions(
                new List<AgentforceGetAuditTrail.Request>{ req }
            );

        Test.stopTest();

        Assert.areEqual(1, responses.size(),
            'One request must produce exactly one response.');
        Assert.areEqual(
            AgentforceActionsLwc.DISABLED_MESSAGE,
            responses[0].result,
            'Agentforce is disabled in this build, so even an unusable agreement Id returns the disabled message rather than an error.');
    }
}