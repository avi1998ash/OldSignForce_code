/**
 * AgentforceSearchAgreements - Agentforce invocable wrapper for SignForce.
 */
public with sharing class AgentforceSearchAgreements {
    @JsonAccess(serializable='always' deserializable='always')
    public class Request {
        @InvocableVariable(label='Search Term' required=true) public String searchTerm;
        @InvocableVariable(label='Max Results') public Integer maxResults;
    }
    @InvocableMethod(label='Search Agreements' description='Search agreements by agreement name or signer name/email.' category='SignForce')
    public static List<Response> getInvocableActions(List<Request> requests) {
        List<Response> out = new List<Response>();
        for (Request req : requests) {
            try { out.add(success(AgentforceActionsLwc.searchAgreements(req.searchTerm, req.maxResults), null)); }
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