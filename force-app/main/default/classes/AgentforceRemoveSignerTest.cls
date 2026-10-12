@IsTest
private class AgentforceRemoveSignerTest {

    @IsTest
    static void testRemoveSignerSuccessAndFailure() {

        Agreement__c agr = new Agreement__c(
            Name = 'Test Agreement'
        );
        insert agr;

        Signer__c signer = new Signer__c(
            Agreement__c = agr.Id,
            Email__c = 'test@example.com'
        );
        insert signer;

        AgentforceRemoveSigner.Request successReq =
            new AgentforceRemoveSigner.Request();

        successReq.signerId = signer.Id;

        AgentforceRemoveSigner.Request failureReq =
            new AgentforceRemoveSigner.Request();

        failureReq.signerId = 'INVALID_ID';

        AgentforceRemoveSigner.Request nullReq = null;

        Test.startTest();

        List<AgentforceRemoveSigner.Response> responses =
            AgentforceRemoveSigner.getInvocableActions(
                new List<AgentforceRemoveSigner.Request>{
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
            'Agentforce is disabled in this build, so removing a signer returns the disabled message instead of deleting the record.');
        Assert.areEqual(false, responses[2].success,
            'A null request cannot be read and must be reported as a failed response, not silently skipped.');
        Assert.areEqual(1, [SELECT COUNT() FROM Signer__c WHERE Id = :signer.Id],
            'The disabled action must touch no data, so the signer it was asked to remove still exists.');
    }

    @IsTest
    static void testEmptyRequestList() {

        List<AgentforceRemoveSigner.Response> responses =
            AgentforceRemoveSigner.getInvocableActions(
                new List<AgentforceRemoveSigner.Request>()
            );

        Assert.areEqual(0, responses.size(),
            'An empty request batch must produce an empty response list, never a null or a placeholder response.');
    }
}