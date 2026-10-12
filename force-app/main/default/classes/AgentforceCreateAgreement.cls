/**
 * AgentforceCreateAgreement - Agentforce invocable wrapper for SignForce.
 */
public with sharing class AgentforceCreateAgreement {
    @JsonAccess(serializable='always' deserializable='always')
    public class Request {
        @InvocableVariable(label='Agreement Name' required=true) public String name;
        @InvocableVariable(label='Agreement Type') public String agreementType;
        @InvocableVariable(label='Signing Order') public String signingOrder;
        @InvocableVariable(label='Message to Signers') public String message;
        @InvocableVariable(label='Expiry Date') public Date expiryDate;
    }
    @InvocableMethod(label='Create SignForce Agreement' description='Create a draft SignForce agreement.' category='SignForce')
    public static List<Response> getInvocableActions(List<Request> requests) {
        List<Response> out = new List<Response>();
        for (Request req : requests) {
            try { out.add(success(AgentforceActionsLwc.createAgreement(req.name, req.agreementType, req.signingOrder, req.message, req.expiryDate), null)); }
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