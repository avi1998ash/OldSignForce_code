/**
 * AgentforceAddSigner - Agentforce invocable wrapper for SignForce.
 */
public with sharing class AgentforceAddSigner {
    @JsonAccess(serializable='always' deserializable='always')
    public class Request {
        @InvocableVariable(label='Agreement Id') public String agreementId;
        @InvocableVariable(label='Agreement Name') public String agreementName;
        @InvocableVariable(label='Signer Name') public String signerName;
        @InvocableVariable(label='Signer Email' required=true) public String email;
        @InvocableVariable(label='Role') public String role;
        @InvocableVariable(label='Signing Order') public Integer signingOrder;
    }
    @InvocableMethod(label='Add Signer' description='Add a signer, approver, or CC to an agreement.' category='SignForce')
    public static List<Response> getInvocableActions(List<Request> requests) {
        List<Response> out = new List<Response>();
        for (Request req : requests) {
            try { out.add(success(AgentforceActionsLwc.addSigner(req.agreementId, req.agreementName, req.signerName, req.email, req.role, req.signingOrder), null)); }
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