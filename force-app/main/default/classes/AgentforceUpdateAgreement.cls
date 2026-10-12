/**
 * AgentforceUpdateAgreement - Agentforce invocable wrapper for SignForce.
 */
public with sharing class AgentforceUpdateAgreement {
    @JsonAccess(serializable='always' deserializable='always')
    public class Request {
        @InvocableVariable(label='Agreement Id') public String agreementId;
        @InvocableVariable(label='Agreement Name') public String agreementName;
        @InvocableVariable(label='New Name') public String newName;
        @InvocableVariable(label='Expiry Date') public Date expiryDate;
        @InvocableVariable(label='Message to Signers') public String message;
    }
    @InvocableMethod(label='Update Agreement' description='Update an agreement name, expiry date, or signer message.' category='SignForce')
    public static List<Response> getInvocableActions(List<Request> requests) {
        List<Response> out = new List<Response>();
        for (Request req : requests) {
            try { out.add(success(AgentforceActionsLwc.updateAgreement(req.agreementId, req.agreementName, req.newName, req.expiryDate, req.message), req.agreementId)); }
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