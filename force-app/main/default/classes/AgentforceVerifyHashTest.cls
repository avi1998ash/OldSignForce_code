@IsTest
private class AgentforceVerifyHashTest {

    @IsTest
    static void testVerifyHashCoverage() {

        Agreement__c agr = new Agreement__c(
            Name = 'Test Agreement'
        );
        insert agr;

        AgentforceVerifyHash.Request successReq =
            new AgentforceVerifyHash.Request();

        successReq.agreementId = agr.Id;

        AgentforceVerifyHash.Request failureReq =
            new AgentforceVerifyHash.Request();

        failureReq.agreementId = 'INVALID_ID';

        AgentforceVerifyHash.Request nullReq = null;

        Test.startTest();

        List<AgentforceVerifyHash.Response> responses =
            AgentforceVerifyHash.getInvocableActions(
                new List<AgentforceVerifyHash.Request>{
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
            'Agentforce is disabled in this build, so a hash check returns the disabled message instead of a valid/invalid verdict.');
        Assert.areEqual(String.valueOf(agr.Id), responses[0].recordId,
            'The wrapper must echo back the agreement Id it was handed so the calling flow can still correlate the response.');
        Assert.areEqual(false, responses[2].success,
            'A null request cannot be read and must be reported as a failed response, not silently skipped.');
    }

    @IsTest
    static void testVerifyHashByName() {

        Agreement__c agr = new Agreement__c(
            Name = 'Verify Agreement'
        );
        insert agr;

        AgentforceVerifyHash.Request req =
            new AgentforceVerifyHash.Request();

        req.agreementName = 'Verify Agreement';

        Test.startTest();

        List<AgentforceVerifyHash.Response> responses =
            AgentforceVerifyHash.getInvocableActions(
                new List<AgentforceVerifyHash.Request>{ req }
            );

        Test.stopTest();

        Assert.areEqual(1, responses.size(),
            'A single request must produce exactly one response.');
        Assert.areEqual(
            AgentforceActionsLwc.DISABLED_MESSAGE,
            responses[0].result,
            'Looking the agreement up by name returns the disabled message too, because the name-based lookup is never reached while Agentforce is off.');
        Assert.isNull(responses[0].recordId,
            'No agreement is resolved from the name while the action is disabled, so the response carries no record Id.');
    }
}