public with sharing class AgentforceProxy {

    private static final String AGENT_API_NAME = 'Copilot_for_Salesforce';
    private static final String AGENT_INVOCABLE_ACTION = 'generateAiAgentResponse';

    // ---------------------------------------------------------------
    // Mockable invoker interface — swap in tests via agentInvoker field
    // ---------------------------------------------------------------
    public interface AgentInvoker {
        List<Invocable.Action.Result> invoke(String userMessage, String sessionId);
    }

    // Real invoker — delegates to the live Agentforce action
    private class RealAgentInvoker implements AgentInvoker {
        public List<Invocable.Action.Result> invoke(String userMessage, String sessionId) {
            Invocable.Action action = Invocable.Action.createCustomAction(
                AGENT_INVOCABLE_ACTION,
                AGENT_API_NAME
            );
            action.setInvocationParameter('userMessage', userMessage);
            if (String.isNotBlank(sessionId)) {
                action.setInvocationParameter('sessionId', sessionId);
            }
            return action.invoke();
        }
    }

    // Injected at test time; production code always uses RealAgentInvoker
    @TestVisible
    private static AgentInvoker agentInvoker = new RealAgentInvoker();

    // ---------------------------------------------------------------
    // Response shape
    // ---------------------------------------------------------------
    public class AgentReply {
        @AuraEnabled public String text;
        @AuraEnabled public String sessionId;
        @AuraEnabled public Boolean success;
    }

    // ---------------------------------------------------------------
    // Main entry point
    // ---------------------------------------------------------------
    @AuraEnabled
    public static AgentReply invokeAgent(String userMessage, String sessionId) {
        AgentReply reply = new AgentReply();
        reply.success = false;

        if (String.isBlank(userMessage)) {
            reply.text = 'Please tell me what you would like to do.';
            return reply;
        }

        try {
            List<Invocable.Action.Result> results = agentInvoker.invoke(userMessage, sessionId);

            if (results == null || results.isEmpty()) {
                reply.text = 'The agent did not respond. Please try again.';
                return reply;
            }

            Invocable.Action.Result result = results[0];
            if (!result.isSuccess()) {
                List<String> errMsgs = new List<String>();
                if (result.getErrors() != null) {
                    for (Invocable.Action.Error e : result.getErrors()) {
                        errMsgs.add(e.getMessage());
                    }
                }
                reply.text = 'Sorry, the agent could not process that: '
                    + (errMsgs.isEmpty() ? 'unknown error' : String.join(errMsgs, '; '));
                return reply;
            }

            Map<String, Object> outputs = result.getOutputParameters();
            if (outputs == null) {
                reply.text = 'The agent returned an empty response.';
                return reply;
            }

            Object rawAgentResponse = outputs.get('agentResponse');
            reply.text = parseAgentText(rawAgentResponse);

            Object returnedSessionId = outputs.get('sessionId');
            reply.sessionId = returnedSessionId == null ? sessionId : String.valueOf(returnedSessionId);

            reply.success = true;
            return reply;

        } catch (Exception ex) {
            reply.text = 'Sorry, I hit an issue reaching the AI assistant: ' + ex.getMessage();
            return reply;
        }
    }

    // ---------------------------------------------------------------
    // parseAgentText — unchanged
    // ---------------------------------------------------------------
    private static String parseAgentText(Object rawAgentResponse) {
        if (rawAgentResponse == null) return 'The agent returned no text.';

        if (rawAgentResponse instanceof Map<String, Object>) {
            Map<String, Object> m = (Map<String, Object>) rawAgentResponse;
            Object val = m.get('value');
            return val == null ? String.valueOf(m) : String.valueOf(val);
        }

        String s = String.valueOf(rawAgentResponse).trim();
        if (String.isBlank(s)) return 'The agent returned an empty response.';

        if (s.startsWith('{') && s.contains('"value"')) {
            try {
                Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(s);
                Object val = parsed.get('value');
                if (val != null) return String.valueOf(val);
            } catch (Exception ignore) {}
        }

        return s;
    }

    @TestVisible
    private static String testParseAgentText(Object rawAgentResponse) {
        return parseAgentText(rawAgentResponse);
    }
}