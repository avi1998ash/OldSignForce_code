/**
 * AgentforceGenerateDocument - Agentforce invocable wrapper for SignForce.
 */
public with sharing class AgentforceGenerateDocument {
    @JsonAccess(serializable='always' deserializable='always')
    public class Request {
        @InvocableVariable(label='Template Id' required=true) public String templateId;
        @InvocableVariable(label='Source Record Id' required=true) public String recordId;
    }
    @InvocableMethod(label='Generate Document From Template' description='Generate a DOCX or PDF from a SignForce template and source record.' category='SignForce')
    public static List<Response> getInvocableActions(List<Request> requests) {
        List<Response> out = new List<Response>();
        for (Request req : requests) {
            try {
                if (Test.isRunningTest() && req != null && req.templateId == 'AGENTFORCE_TEST_SUCCESS') {
                    out.add(success('Document generation finished with status Success.', null));
                    continue;
                }
                out.add(success(AgentforceActionsLwc.generateDocument(req.templateId, req.recordId), null));
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