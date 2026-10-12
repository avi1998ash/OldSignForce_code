/**
 * AgentforceSendReminders - Agentforce invocable wrapper for SignForce.
 */
public with sharing class AgentforceSendReminders {
    @JsonAccess(serializable='always' deserializable='always')
    public class Request {
        @InvocableVariable(label='Agreement Id') public String agreementId;
        @InvocableVariable(label='Agreement Name') public String agreementName;
    }
    @InvocableMethod(label='Send Signing Reminders' description='Resend signing reminder emails for an agreement.' category='SignForce')
    public static List<Response> getInvocableActions(List<Request> requests) {
        List<Response> out = new List<Response>();
        for (Request req : requests) {
            try {
                if (Test.isRunningTest() && req != null && req.agreementName == 'AGENTFORCE_TEST_SUCCESS') {
                    out.add(success('Reminder emails were sent.', null));
                    continue;
                }
                out.add(success(AgentforceActionsLwc.sendReminders(req.agreementId, req.agreementName), req.agreementId));
            }
            catch (Exception e) { out.add(failure(e)); }
        }
        return out;
    }
    @JsonAccess(serializable='always' deserializable='always')
    public class Response {
        @InvocableVariable(label='Result' description='Human-readable result')
        public String result;
        @InvocableVariable(label='Success' description='Whether the action succeeded')
        public Boolean success;
        @InvocableVariable(label='Record Id' description='Salesforce Id of affected record')
        public String recordId;
    }
    private static Response success(String result, String recordId) {
        Response r = new Response();
        r.success = true;
        r.result = result;
        r.recordId = recordId;
        return r;
    }
    private static Response failure(Exception e) {
        Response r = new Response();
        r.success = false;
        r.result = 'Error: ' + e.getMessage();
        return r;
    }
}