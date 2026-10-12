/**
 * AgentforceCreateTemplate - Agentforce invocable wrapper for SignForce.
 */
public with sharing class AgentforceCreateTemplate {
    @JsonAccess(serializable='always' deserializable='always')
    public class Request {
        @InvocableVariable(label='Template Name' required=true) public String name;
        @InvocableVariable(label='Object API Name' required=true) public String objectApiName;
        @InvocableVariable(label='Content Version Id' required=true) public String contentVersionId;
        @InvocableVariable(label='Output Format') public String outputFormat;
        @InvocableVariable(label='Active') public Boolean active;
        @InvocableVariable(label='Auto Create Agreement') public Boolean autoCreateAgreement;
        @InvocableVariable(label='Default Agreement Type') public String defaultAgreementType;
        @InvocableVariable(label='Description') public String description;
    }
    @InvocableMethod(label='Create SignForce Template' description='Create a new document template from an uploaded DOCX ContentVersion.' category='SignForce')
    public static List<Response> getInvocableActions(List<Request> requests) {
        List<Response> out = new List<Response>();
        for (Request req : requests) {
            try {
                String msg = AgentforceActionsLwc.createTemplate(req.name, req.objectApiName, req.contentVersionId, req.outputFormat, req.active, req.autoCreateAgreement, req.defaultAgreementType, req.description);
                out.add(success(msg, null));
            } catch (Exception e) { out.add(failure(e)); }
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