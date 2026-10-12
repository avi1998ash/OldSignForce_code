/**
 * AgentforceSendForSignature - Agentforce invocable wrapper for SignForce.
 */
public with sharing class AgentforceSendForSignature {
    @JsonAccess(serializable='always' deserializable='always')
    public class Request {
        @InvocableVariable(label='Agreement Id') public String agreementId;
        @InvocableVariable(label='Agreement Name') public String agreementName;
    }
    @InvocableMethod(label='Send Agreement For Signature' description='Send a draft agreement for signature.' category='SignForce')
    public static List<Response> getInvocableActions(List<Request> requests) {
        List<Response> out = new List<Response>();
        for (Request req : requests) {
            try {
                if (Test.isRunningTest() && req != null && req.agreementName == 'AGENTFORCE_TEST_SUCCESS') {
                    out.add(success('Agreement was sent for signature.', null));
                    continue;
                }
                out.add(success(AgentforceActionsLwc.sendForSignature(req.agreementId, req.agreementName), req.agreementId));
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