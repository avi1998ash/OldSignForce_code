@IsTest
private class AgentforceCreateTemplateTest {
    
    @IsTest
    static void testGetInvocableActions() {
        
        AgentforceCreateTemplate.Request req =
            new AgentforceCreateTemplate.Request();
        
        req.name = 'Test Template';
        req.objectApiName = 'Account';
        req.contentVersionId = '068000000000001AAA';
        req.outputFormat = 'PDF';
        req.active = true;
        req.autoCreateAgreement = true;
        req.defaultAgreementType = 'Standard';
        req.description = 'Test Description';
        
        List<AgentforceCreateTemplate.Request> requests =
            new List<AgentforceCreateTemplate.Request>{ req };
                
                Test.startTest();
        List<AgentforceCreateTemplate.Response> responses =
            AgentforceCreateTemplate.getInvocableActions(requests);
        Test.stopTest();
        
        System.assertEquals(1, responses.size());
        
        AgentforceCreateTemplate.Response res = responses[0];
        
        System.assertNotEquals(null, res);
        System.assertNotEquals(null, res.success);
        System.assertNotEquals(null, res.result);
    }
    
    @IsTest
    static void testEmptyRequestList() {
        
        Test.startTest();
        List<AgentforceCreateTemplate.Response> responses =
            AgentforceCreateTemplate.getInvocableActions(
                new List<AgentforceCreateTemplate.Request>()
            );
        Test.stopTest();

        System.assertEquals(0, responses.size(),
            'An empty request list must produce no responses at all.');
    }
    @IsTest
    static void testFailureScenario() {
        
        AgentforceCreateTemplate.Request req =
            new AgentforceCreateTemplate.Request();
        
        req.name = 'Test';
        req.objectApiName = 'Account';
        req.contentVersionId = null; 
        
        Test.startTest();
        List<AgentforceCreateTemplate.Response> result =
            AgentforceCreateTemplate.getInvocableActions(
                new List<AgentforceCreateTemplate.Request>{req}
            );
        Test.stopTest();

        System.assertEquals(1, result.size(),
            'One request must produce exactly one response.');
        System.assertEquals(AgentforceActionsLwc.DISABLED_MESSAGE, result[0].result,
            'Agentforce is disabled in this build, so a missing Content Version Id never reaches template registration; the disabled message comes back instead.');
    }
    @IsTest
    static void testGetInvocableActions_Failure() {
        
        AgentforceCreateTemplate.Request req =
            new AgentforceCreateTemplate.Request();
        
        req.name = ''; 
        req.objectApiName = 'Account';
        req.contentVersionId = '068000000000001AAA';
        
        Test.startTest();
        
        List<AgentforceCreateTemplate.Response> result =
            AgentforceCreateTemplate.getInvocableActions(
                new List<AgentforceCreateTemplate.Request>{ req }
            );
        
        Test.stopTest();
        
        System.debug(result);

        System.assertEquals(1, result.size(),
            'A single request must yield a single response even when the template name is blank.');
        System.assertEquals(AgentforceActionsLwc.DISABLED_MESSAGE, result[0].result,
            'Agentforce is disabled in this build, so a blank template name never reaches name validation; the disabled message comes back instead.');
    }
}