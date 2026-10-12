/**
 * AgentforceActions — DISABLED.
 *
 * Agentforce is switched off in this build. SignForceAccess.isAgentforceUiEnabled()
 * already returns false unconditionally, so nothing in the product reaches this
 * class; what remained was the code itself, and it carried the bulk of the
 * security-scan findings, including every critical SOQL-injection path.
 *
 * The public signatures are deliberately kept. Sixteen genAiFunction metadata
 * files bind to the invocable wrappers that call in here, so removing a method
 * would stop the package deploying. Each one now returns DISABLED_MESSAGE and
 * touches no data.
 *
 * The original implementation is preserved verbatim below, line-commented.
 * Switching Agentforce back on is an un-comment, not a rewrite.
 */
public with sharing class AgentforceActions {

    @TestVisible
    private static final String DISABLED_MESSAGE =
        'The SignForce assistant is not enabled in this org.';

    public class StatusRequest {
        @InvocableVariable(label='Agreement Name' description='Name of the agreement to check' required=true)
        public String agreementName;
    }

    public class StatusResponse {
        @InvocableVariable(label='Result Summary')
        public String resultSummary;

        @InvocableVariable(label='Agreement Id')
        public String agreementId;
    }

    private static List<StatusResponse> disabledResponses(List<StatusRequest> requests) {
        List<StatusResponse> out = new List<StatusResponse>();
        Integer n = (requests == null || requests.isEmpty()) ? 1 : requests.size();
        for (Integer i = 0; i < n; i++) {
            StatusResponse r = new StatusResponse();
            r.resultSummary = DISABLED_MESSAGE;
            out.add(r);
        }
        return out;
    }

    @InvocableMethod(label='Get SignForce Agreement Status' description='Returns the current status of a SignForce agreement by name match.' category='SignForce')
    public static List<StatusResponse> getStatus(List<StatusRequest> requests) {
        return disabledResponses(requests);
    }

    public static String listPendingSummary(Integer maxResults) {
        return DISABLED_MESSAGE;
    }

    /* ═══════════════════════════════════════════════════════════════
       ORIGINAL IMPLEMENTATION — kept for the day Agentforce is turned
       back on. Nothing below this line executes.
       ═══════════════════════════════════════════════════════════ */
// public with sharing class AgentforceActions {
//
//     public class StatusRequest {
//         @InvocableVariable(label='Agreement Name' description='Name of the agreement to check' required=true)
//         public String agreementName;
//     }
//
//     public class StatusResponse {
//         @InvocableVariable(label='Result Summary')
//         public String resultSummary;
//
//         @InvocableVariable(label='Agreement Id')
//         public String agreementId;
//     }
//
//     @InvocableMethod(label='Get SignForce Agreement Status' description='Returns the current status of a SignForce agreement by name match.' category='SignForce')
//     public static List<StatusResponse> getStatus(List<StatusRequest> requests) {
//         List<StatusResponse> out = new List<StatusResponse>();
//         for (StatusRequest req : requests) {
//             StatusResponse resp = new StatusResponse();
//             try {
//                 String searchName = (req.agreementName == null) ? '' : req.agreementName.trim();
//                 if (String.isBlank(searchName)) {
//                     resp.resultSummary = 'Please tell me which agreement to check.';
//                     out.add(resp);
//                     continue;
//                 }
//                 String searchPattern = '%' + searchName + '%';
//                 List<Agreement__c> agreements = [
//                     SELECT Id, Name, Status__c, Expiry_Date__c
//                     FROM Agreement__c
//                     WHERE Name LIKE :searchPattern
//                     ORDER BY CreatedDate DESC
//                     LIMIT 3
//                 ];
//                 if (agreements.isEmpty()) {
//                     resp.resultSummary = 'No agreement found matching "' + searchName + '".';
//                 } else if (agreements.size() == 1) {
//                     Agreement__c ag = agreements[0];
//                     String expiry = (ag.Expiry_Date__c != null)
//                         ? ' It expires on ' + ag.Expiry_Date__c.format('MMMM d, yyyy') + '.'
//                         : ' No expiry date is set.';
//                     resp.resultSummary = 'The agreement "' + ag.Name + '" is currently ' + ag.Status__c + '.' + expiry;
//                     resp.agreementId = ag.Id;
//                 } else {
//                     String msg = 'I found ' + agreements.size() + ' matching agreements: ';
//                     for (Agreement__c ag : agreements) {
//                         msg += ag.Name + ' (' + ag.Status__c + '), ';
//                     }
//                     msg = msg.removeEnd(', ') + '. Which one did you mean?';
//                     resp.resultSummary = msg;
//                 }
//             } catch (Exception e) {
//                 resp.resultSummary = 'Sorry, I hit an error: ' + e.getMessage();
//             }
//             out.add(resp);
//         }
//         return out;
//     }
//
//     // Pending lookup — exposed as a regular static method (not InvocableMethod)
//     // because Apex limits each class to one @InvocableMethod. This is still
//     // callable from the LWC and from other Apex; for Agentforce wiring, this
//     // helper can be wrapped in a separate class later.
//     public static String listPendingSummary(Integer maxResults) {
//         Integer lim = (maxResults != null && maxResults > 0) ? maxResults : 5;
//         try {
//             List<Agreement__c> pending = [
//                 SELECT Id, Name, Status__c, Expiry_Date__c
//                 FROM Agreement__c
//                 WHERE Status__c IN ('Sent', 'In Progress', 'Pending Signature')
//                 ORDER BY CreatedDate DESC
//                 LIMIT :lim
//             ];
//             if (pending.isEmpty()) {
//                 return 'No agreements pending signature.';
//             }
//             String msg = 'You have ' + pending.size() + ' agreement(s) pending: ';
//             for (Agreement__c ag : pending) {
//                 msg += ag.Name + ' (' + ag.Status__c + '), ';
//             }
//             return msg.removeEnd(', ') + '.';
//         } catch (Exception e) {
//             return 'Sorry, I hit an error: ' + e.getMessage();
//         }
//     }
// }
}