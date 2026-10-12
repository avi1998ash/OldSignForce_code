@IsTest
private class AgentforceProxyTest {

    // ---------------------------------------------------------------
    // Stub: returns null list → covers "results == null" branch
    // ---------------------------------------------------------------
    private class NullResultsInvoker implements AgentforceProxy.AgentInvoker {
        public List<Invocable.Action.Result> invoke(String userMessage, String sessionId) {
            return null;
        }
    }

    // ---------------------------------------------------------------
    // Stub: returns empty list → covers "results.isEmpty()" branch
    // ---------------------------------------------------------------
    private class EmptyResultsInvoker implements AgentforceProxy.AgentInvoker {
        public List<Invocable.Action.Result> invoke(String userMessage, String sessionId) {
            return new List<Invocable.Action.Result>();
        }
    }

    // ---------------------------------------------------------------
    // Stub: throws exception → covers catch (Exception ex) branch
    // ---------------------------------------------------------------
    private class ThrowingInvoker implements AgentforceProxy.AgentInvoker {
        public List<Invocable.Action.Result> invoke(String userMessage, String sessionId) {
            throw new System.CalloutException('Simulated failure');
        }
    }

    // ---------------------------------------------------------------
    // Tests for parseAgentText (unchanged — already passing)
    // ---------------------------------------------------------------
    @IsTest
    static void testParseAgentTextCoverage() {
        String fromNull = AgentforceProxy.testParseAgentText(null);
        String fromPlainText = AgentforceProxy.testParseAgentText('Hello World');
        String fromJson = AgentforceProxy.testParseAgentText('{"type":"Text","value":"Agent Response"}');
        String fromMap = AgentforceProxy.testParseAgentText(new Map<String,Object>{'value' => 'Map Response'});
        String fromMalformedJson = AgentforceProxy.testParseAgentText('{"value":');  // malformed JSON — hits catch(ignore)

        System.assertEquals('The agent returned no text.', fromNull,
            'A null agent response must become a readable fallback, never a null the LWC would render as blank.');
        System.assertEquals('Hello World', fromPlainText,
            'A plain-text agent response must be passed through unchanged.');
        System.assertEquals('Agent Response', fromJson,
            'A JSON agent response must be unwrapped to its value, not shown to the user as raw JSON.');
        System.assertEquals('Map Response', fromMap,
            'A Map agent response must be unwrapped to its value key.');
        System.assertEquals('{"value":', fromMalformedJson,
            'Malformed JSON must fall back to the raw string rather than throwing out of the parser.');
    }

    // ---------------------------------------------------------------
    // Covers: blank/null userMessage guard
    // ---------------------------------------------------------------
    @IsTest
    static void testBlankMessage() {
        Test.startTest();
        AgentforceProxy.AgentReply r1 = AgentforceProxy.invokeAgent(null, null);
        AgentforceProxy.AgentReply r2 = AgentforceProxy.invokeAgent('', null);
        Test.stopTest();

        System.assertEquals(false, r1.success);
        System.assertEquals(false, r2.success);
    }

    // ---------------------------------------------------------------
    // Covers: results == null path
    // ---------------------------------------------------------------
    @IsTest
    static void testNullResultsList() {
        AgentforceProxy.agentInvoker = new NullResultsInvoker();
        Test.startTest();
        AgentforceProxy.AgentReply reply = AgentforceProxy.invokeAgent('Hello', null);
        Test.stopTest();

        System.assertEquals(false, reply.success);
        System.assert(reply.text.contains('did not respond'));
    }

    // ---------------------------------------------------------------
    // Covers: results.isEmpty() path
    // ---------------------------------------------------------------
    @IsTest
    static void testEmptyResultsList() {
        AgentforceProxy.agentInvoker = new EmptyResultsInvoker();
        Test.startTest();
        AgentforceProxy.AgentReply reply = AgentforceProxy.invokeAgent('Hello', null);
        Test.stopTest();

        System.assertEquals(false, reply.success);
        System.assert(reply.text.contains('did not respond'));
    }

    // ---------------------------------------------------------------
    // Covers: catch (Exception ex) path
    // ---------------------------------------------------------------
    @IsTest
    static void testExceptionPath() {
        AgentforceProxy.agentInvoker = new ThrowingInvoker();
        Test.startTest();
        AgentforceProxy.AgentReply reply = AgentforceProxy.invokeAgent('Hello', 'session-1');
        Test.stopTest();

        System.assertEquals(false, reply.success);
        System.assert(reply.text.contains('hit an issue'));
    }

    // ---------------------------------------------------------------
    // Original happy-path / live call test (kept as-is)
    // ---------------------------------------------------------------
    @IsTest
    static void testInvokeAgentLivePaths() {
        Test.startTest();
        AgentforceProxy.AgentReply newSessionReply = AgentforceProxy.invokeAgent('Create an agreement', null);
        AgentforceProxy.AgentReply existingSessionReply = AgentforceProxy.invokeAgent('Hello', 'session-1');
        Test.stopTest();

        System.assertNotEquals(null, newSessionReply,
            'invokeAgent must always hand back a reply object, never null, whatever the live action does.');
        System.assert(String.isNotBlank(newSessionReply.text),
            'Every reply must carry user-facing text, so the chat panel never renders an empty bubble.');
        System.assertNotEquals(null, newSessionReply.success,
            'The reply must always state whether the agent call succeeded.');
        System.assert(String.isNotBlank(existingSessionReply.text),
            'A message sent with an existing session id must also come back with user-facing text.');
    }
}