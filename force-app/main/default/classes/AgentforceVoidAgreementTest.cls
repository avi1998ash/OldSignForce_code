@IsTest
private class AgentforceVoidAgreementTest {

    @IsTest
    static void testVoidAgreementCoverage() {

        Agreement__c agr = new Agreement__c(
            Name = 'Test Agreement'
        );
        insert agr;

        AgentforceVoidAgreement.Request successReq =
            new AgentforceVoidAgreement.Request();

        successReq.agreementId = agr.Id;
        successReq.reason = 'Test Void';

        AgentforceVoidAgreement.Request failureReq =
            new AgentforceVoidAgreement.Request();

        failureReq.agreementId = 'INVALID_ID';
        failureReq.reason = 'Failure Test';

        AgentforceVoidAgreement.Request nullReq = null;

        Test.startTest();

        List<AgentforceVoidAgreement.Response> responses =
            AgentforceVoidAgreement.getInvocableActions(
                new List<AgentforceVoidAgreement.Request>{
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
            'Agentforce is disabled in this build, so a void request returns the disabled message instead of a void confirmation.');
        Assert.areEqual(false, responses[2].success,
            'A null request cannot be read and must be reported as a failed response, not silently skipped.');

        Agreement__c reloaded = [SELECT Status__c FROM Agreement__c WHERE Id = :agr.Id];
        Assert.areNotEqual('Voided', reloaded.Status__c,
            'Voiding is irreversible, so the disabled action must leave the agreement status alone rather than void it.');
    }

    @IsTest
    static void testVoidAgreementByName() {

        Agreement__c agr = new Agreement__c(
            Name = 'Agreement By Name'
        );
        insert agr;

        AgentforceVoidAgreement.Request req =
            new AgentforceVoidAgreement.Request();

        req.agreementName = 'Agreement By Name';
        req.reason = 'Void By Name';

        Test.startTest();

        List<AgentforceVoidAgreement.Response> responses =
            AgentforceVoidAgreement.getInvocableActions(
                new List<AgentforceVoidAgreement.Request>{ req }
            );

        Test.stopTest();

        Assert.areEqual(1, responses.size(),
            'A single request must produce exactly one response.');
        Assert.areEqual(
            AgentforceActionsLwc.DISABLED_MESSAGE,
            responses[0].result,
            'Voiding by name returns the disabled message too, because the name-based lookup is never reached while Agentforce is off.');

        Agreement__c reloaded = [SELECT Status__c FROM Agreement__c WHERE Id = :agr.Id];
        Assert.areNotEqual('Voided', reloaded.Status__c,
            'The agreement matched by name must be left untouched, not voided, while the action is disabled.');
    }
}