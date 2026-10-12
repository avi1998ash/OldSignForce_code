/**
 * AgentforceUploadDocument - Agentforce invocable wrapper for SignForce.
 */
public with sharing class AgentforceUploadDocument {
    @JsonAccess(serializable='always' deserializable='always')
    public class Request {
        @InvocableVariable(label='Agreement Id' required=true) public String agreementId;
        @InvocableVariable(label='File Name' required=true) public String fileName;
        @InvocableVariable(label='PDF Base64' required=true) public String pdfBase64;
        @InvocableVariable(label='File Size Bytes') public Decimal fileSize;
    }
    @InvocableMethod(label='Upload Agreement Document' description='Upload a PDF document to a SignForce agreement.' category='SignForce')
    public static List<Response> getInvocableActions(List<Request> requests) {
        List<Response> out = new List<Response>();
        for (Request req : requests) {
            try { out.add(success(AgentforceActionsLwc.uploadDocument(req.agreementId, req.fileName, req.pdfBase64, req.fileSize), null)); }
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