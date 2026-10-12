@IsTest
private class AgentforceUpdateAgreementTest {

    @IsTest
    static void testUpdateAgreementCoverage() {

        Agreement__c agr = new Agreement__c(
            Name = 'Test Agreement'
        );
        insert agr;

        AgentforceUpdateAgreement.Request successReq =
            new AgentforceUpdateAgreement.Request();

        successReq.agreementId = agr.Id;
        successReq.newName = 'Updated Agreement';
        successReq.expiryDate = Date.today().addDays(30);
        successReq.message = 'Updated Message';

        AgentforceUpdateAgreement.Request failureReq =
            new AgentforceUpdateAgreement.Request();

        failureReq.agreementId = 'INVALID_ID';
        failureReq.newName = 'Fail';

        AgentforceUpdateAgreement.Request nullReq = null;

        Test.startTest();

        List<AgentforceUpdateAgreement.Response> responses =
            AgentforceUpdateAgreement.getInvocableActions(
                new List<AgentforceUpdateAgreement.Request>{
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
            'Agentforce is disabled in this build, so an update request returns the disabled message rather than an update confirmation.');
        Assert.areEqual(String.valueOf(agr.Id), responses[0].recordId,
            'The wrapper must echo back the agreement Id it was handed so the calling flow can still correlate the response.');
        Assert.areEqual(false, responses[2].success,
            'A null request cannot be read and must be reported as a failed response, not silently skipped.');

        Agreement__c reloaded = [SELECT Name FROM Agreement__c WHERE Id = :agr.Id];
        Assert.areEqual('Test Agreement', reloaded.Name,
            'The disabled action must touch no data, so the requested rename to "Updated Agreement" must not have been applied.');
    }

    @IsTest
    static void testNoUpdatesProvided() {

        Agreement__c agr = new Agreement__c(
            Name = 'No Update Agreement'
        );
        insert agr;

        AgentforceUpdateAgreement.Request req =
            new AgentforceUpdateAgreement.Request();

        req.agreementId = agr.Id;

        Test.startTest();

        List<AgentforceUpdateAgreement.Response> responses =
            AgentforceUpdateAgreement.getInvocableActions(
                new List<AgentforceUpdateAgreement.Request>{ req }
            );

        Test.stopTest();

        Assert.areEqual(1, responses.size(),
            'A single request must produce exactly one response.');
        Assert.areEqual(
            AgentforceActionsLwc.DISABLED_MESSAGE,
            responses[0].result,
            'A request carrying no field changes still returns the disabled message, because the action never reaches the "no updates provided" branch while Agentforce is off.');
    }
}