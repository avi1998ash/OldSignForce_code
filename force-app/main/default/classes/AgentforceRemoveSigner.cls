/**
 * AgentforceRemoveSigner - Agentforce invocable wrapper for SignForce.
 */
public with sharing class AgentforceRemoveSigner {
    @JsonAccess(serializable='always' deserializable='always')
    public class Request {
        @InvocableVariable(label='Signer Id') public String signerId;
        @InvocableVariable(label='Agreement Id') public String agreementId;
        @InvocableVariable(label='Agreement Name') public String agreementName;
        @InvocableVariable(label='Signer Email') public String email;
    }
    @InvocableMethod(label='Remove Signer' description='Remove a signer from an agreement.' category='SignForce')
    public static List<Response> getInvocableActions(List<Request> requests) {
        List<Response> out = new List<Response>();
        for (Request req : requests) {
            try { out.add(success(AgentforceActionsLwc.removeSigner(req.signerId, req.agreementId, req.agreementName, req.email), req.signerId)); }
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