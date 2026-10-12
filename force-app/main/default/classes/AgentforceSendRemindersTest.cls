@IsTest
private class AgentforceSendRemindersTest {

    @IsTest
    static void testSendRemindersCoverage() {

        AgentforceSendReminders.Request successReq =
            new AgentforceSendReminders.Request();

        successReq.agreementName = 'AGENTFORCE_TEST_SUCCESS';

        AgentforceSendReminders.Request failureReq =
            new AgentforceSendReminders.Request();

        failureReq.agreementId = 'INVALID_ID';
        failureReq.agreementName = null;

        AgentforceSendReminders.Request nullReq = null;

        Test.startTest();

        List<AgentforceSendReminders.Response> responses =
            AgentforceSendReminders.getInvocableActions(
                new List<AgentforceSendReminders.Request>{
                    successReq,
                    failureReq,
                    nullReq
                }
            );

        Test.stopTest();

        Assert.areEqual(3, responses.size(),
            'The wrapper must return one response per request, including the null one.');
        Assert.areEqual('Reminder emails were sent.', responses[0].result,
            'The in-test short-circuit branch must report reminders as sent without calling the disabled implementation.');
        Assert.areEqual(
            AgentforceActionsLwc.DISABLED_MESSAGE,
            responses[1].result,
            'Agentforce is disabled in this build, so a real reminder run returns the disabled message instead of an agreement lookup error.');
        Assert.areEqual(false, responses[2].success,
            'A null request cannot be read and must be reported as a failed response, not silently skipped.');
    }

    @IsTest
    static void testEmptyRequestList() {

        Test.startTest();

        List<AgentforceSendReminders.Response> responses =
            AgentforceSendReminders.getInvocableActions(
                new List<AgentforceSendReminders.Request>()
            );

        Test.stopTest();

        Assert.areEqual(0, responses.size(),
            'An empty request batch must produce an empty response list, never a null or a placeholder response.');
    }
}