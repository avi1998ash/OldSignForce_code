@IsTest
private class AgentforceGetStatusTest {

    @IsTest
    static void testCoverage() {

        Agreement__c agr = new Agreement__c(
            Name = 'Test Agreement'
        );
        insert agr;

        AgentforceGetStatus.Request req1 =
            new AgentforceGetStatus.Request();

        req1.agreementId = agr.Id;
        req1.agreementName = null;

        AgentforceGetStatus.Request req2 =
            new AgentforceGetStatus.Request();

        req2.agreementId = null;
        req2.agreementName = agr.Name;

        AgentforceGetStatus.Request req3 =
            new AgentforceGetStatus.Request();

        req3.agreementId = 'INVALID_ID';

        AgentforceGetStatus.Request req4 =
            null;

        Test.startTest();

        List<AgentforceGetStatus.Response> results =
        AgentforceGetStatus.getInvocableActions(
            new List<AgentforceGetStatus.Request>{
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
            'Agentforce is disabled, so a lookup by Id must return the disabled message');
        Assert.areEqual(AgentforceActionsLwc.DISABLED_MESSAGE, results[1].result,
            'Agentforce is disabled, so a lookup by name must return the disabled message');
        Assert.areEqual(String.valueOf(agr.Id), results[0].recordId,
            'The response must echo back the agreement Id it was asked about');
        Assert.areEqual(false, results[3].success,
            'A null request must be reported as a failure rather than silently succeeding');
    }
}