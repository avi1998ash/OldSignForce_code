/**
 * AgentforceActionsLwc — DISABLED.
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
public with sharing class AgentforceActionsLwc {

    @TestVisible
    private static final String DISABLED_MESSAGE =
        'The SignForce assistant is not enabled in this org.';

    /* Lifted verbatim from the original: a plain data holder, no logic and
       therefore no findings, and any caller that names the type keeps working. */
    public class ActionResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String result;
        @AuraEnabled public String recordId;
        @AuraEnabled public String payloadJson;
    }

    @AuraEnabled
    public static String routeMessage(String message) {
        return DISABLED_MESSAGE;
    }

    @AuraEnabled
    public static String confirmLastAction(String pendingJson) {
        return DISABLED_MESSAGE;
    }

    @AuraEnabled
    public static String createTemplate(String name, String objectApiName, String contentVersionId, String outputFormat, Boolean active, Boolean autoCreateAgreement, String defaultAgreementType, String description) {
        return DISABLED_MESSAGE;
    }

    @AuraEnabled
    public static String createAgreement(String name, String agreementType, String signingOrder, String message, Date expiryDate) {
        return DISABLED_MESSAGE;
    }

    @AuraEnabled
    public static String uploadDocument(String agreementId, String fileName, String pdfBase64, Decimal fileSize) {
        return DISABLED_MESSAGE;
    }

    @AuraEnabled
    public static String generateDocument(String templateId, String recordId) {
        return DISABLED_MESSAGE;
    }

    @AuraEnabled
    public static String addSigner(String agreementId, String agreementName, String signerName, String email, String role, Integer signingOrder) {
        return DISABLED_MESSAGE;
    }

    @AuraEnabled
    public static String removeSigner(String signerId, String agreementId, String agreementName, String email) {
        return DISABLED_MESSAGE;
    }

    @AuraEnabled
    public static String updateAgreement(String agreementId, String agreementName, String newName, Date expiryDate, String message) {
        return DISABLED_MESSAGE;
    }

    @AuraEnabled
    public static String sendForSignature(String agreementId, String agreementName) {
        return DISABLED_MESSAGE;
    }

    @AuraEnabled
    public static String getStatus(String agreementId, String agreementName) {
        return DISABLED_MESSAGE;
    }

    @AuraEnabled
    public static String listPending(Integer maxResults) {
        return DISABLED_MESSAGE;
    }

    @AuraEnabled
    public static String searchAgreements(String searchTerm, Integer maxResults) {
        return DISABLED_MESSAGE;
    }

    @AuraEnabled
    public static String listTemplates(String objectApiName) {
        return DISABLED_MESSAGE;
    }

    @AuraEnabled
    public static String sendReminders(String agreementId, String agreementName) {
        return DISABLED_MESSAGE;
    }

    @AuraEnabled
    public static String voidAgreement(String agreementId, String agreementName, String reason) {
        return DISABLED_MESSAGE;
    }

    @AuraEnabled
    public static String verifyHash(String agreementId, String agreementName) {
        return DISABLED_MESSAGE;
    }

    @AuraEnabled
    public static String getAuditTrail(String agreementId, String agreementName, Integer maxResults) {
        return DISABLED_MESSAGE;
    }

    /* ═══════════════════════════════════════════════════════════════
       ORIGINAL IMPLEMENTATION — kept for the day Agentforce is turned
       back on. Nothing below this line executes.
       ═══════════════════════════════════════════════════════════ */
// public with sharing class AgentforceActionsLwc {
//     public class ActionResult {
//         @AuraEnabled public Boolean success;
//         @AuraEnabled public String result;
//         @AuraEnabled public String recordId;
//         @AuraEnabled public String payloadJson;
//     }
//
//     private static ActionResult ok(String message, Id recordId) {
//         ActionResult r = new ActionResult();
//         r.success = true;
//         r.result = message;
//         r.recordId = recordId == null ? null : String.valueOf(recordId);
//         return r;
//     }
//
//     private static ActionResult fail(Exception e) {
//         ActionResult r = new ActionResult();
//         r.success = false;
//         r.result = 'Error: ' + e.getMessage();
//         return r;
//     }
//
//     private static Id toId(String value, String label) {
//         if (String.isBlank(value)) throw new AuraHandledException(label + ' is required');
//         return (Id) value.trim();
//     }
//
//     private static Agreement__c findAgreement(String agreementId, String agreementName) {
//         if (String.isNotBlank(agreementId)) {
//             List<Agreement__c> byId = [
//                 SELECT Id, Name, Status__c, Expiry_Date__c, Message_to_Signers__c,
//                        Agreement_Type__c, Signing_Order__c
//                 FROM Agreement__c
//                 WHERE Id = :toId(agreementId, 'Agreement Id')
//                 WITH SECURITY_ENFORCED
//                 LIMIT 1
//             ];
//             if (!byId.isEmpty()) return byId[0];
//         }
//         if (String.isBlank(agreementName)) throw new AuraHandledException('Agreement name is required');
//         String term = '%' + String.escapeSingleQuotes(agreementName.trim()) + '%';
//         List<Agreement__c> rows = [
//             SELECT Id, Name, Status__c, Expiry_Date__c, Message_to_Signers__c,
//                    Agreement_Type__c, Signing_Order__c
//             FROM Agreement__c
//             WHERE Name LIKE :term
//             WITH SECURITY_ENFORCED
//             ORDER BY LastModifiedDate DESC
//             LIMIT 2
//         ];
//         if (rows.isEmpty()) throw new AuraHandledException('No agreement found matching "' + agreementName + '".');
//         if (rows.size() > 1) throw new AuraHandledException('Multiple agreements match "' + agreementName + '". Please provide the agreement Id or exact name.');
//         return rows[0];
//     }
//
//     private static String dateTimeText(DateTime dt) {
//         return dt == null ? 'not set' : dt.format();
//     }
//
//     @AuraEnabled
//     public static String routeMessage(String message) {
//         // Wraps everything so we always return a friendly string, never throw.
//         // For DML/write operations, we return a PREVIEW first (action description
//         // plus prompt to confirm). The LWC tracks the pending action in state
//         // and calls confirmLastAction once the user replies "yes".
//         try {
//             String lower = String.isBlank(message) ? '' : message.toLowerCase().trim();
//
//             // ── Confirmation responses (handled by LWC state, not here) ──
//             // The LWC intercepts "yes/no/confirm/cancel" before calling routeMessage
//             // when a pending action exists. If routeMessage receives one of these
//             // directly, it means no pending action — gently inform the user.
//             if (lower == 'yes' || lower == 'confirm' || lower == 'do it'
//                 || lower == 'no' || lower == 'cancel' || lower == 'stop'
//                 || lower == 'abort') {
//                 return 'There is nothing pending to confirm. Tell me what you would like to do.';
//             }
//
//             // ── Greetings ──
//             if (lower == '' || lower == 'hi' || lower == 'hello' || lower == 'hey'
//                 || lower.startsWith('hi ') || lower.startsWith('hello ')
//                 || lower.startsWith('hey ')) {
//                 return 'Hi! I can help with SignForce agreements. Try asking:\n'
//                     + '- "What\'s the status of [agreement name]?"\n'
//                     + '- "Send [agreement name] for signature"\n'
//                     + '- "Void [agreement name], [reason]"\n'
//                     + '- "Send reminders for [agreement name]"\n'
//                     + '- "What\'s pending signature?"';
//             }
//
//             if (lower.contains('help') || lower.contains('what can you do')) {
//                 return 'I can:\n'
//                     + 'READ: status, list pending, search, templates, audit, verify hash\n'
//                     + 'WRITE (asks confirmation first): send for signature, void/cancel, '
//                     + 'send reminders, update expiry, add/remove signer, generate document\n'
//                     + 'Just ask in natural language!';
//             }
//
//             // ════════════════════════════════════════════════════════════
//             // WRITE OPERATIONS — return PREVIEW, ask for confirmation
//             // ════════════════════════════════════════════════════════════
//
//             // 1. SEND FOR SIGNATURE
//             if (containsAny(lower, new List<String>{ 'send for signature', 'send for sign',
//                     'send the', 'send it for', 'submit for signature' })) {
//                 return previewSendForSignature(extractName(message));
//             }
//
//             // 2. VOID / CANCEL agreement
//             if (containsAny(lower, new List<String>{ 'void', 'cancel agreement', 'cancel the',
//                     'terminate agreement', 'withdraw agreement', 'kill the' })) {
//                 return previewVoidAgreement(extractName(message), extractReason(message));
//             }
//
//             // 3. SEND REMINDERS
//             if (containsAny(lower, new List<String>{ 'remind', 'remember', 'follow up',
//                     'nudge signers', 'send reminder' })) {
//                 return previewSendReminders(extractName(message));
//             }
//
//             // 4. UPDATE AGREEMENT (expiry / message)
//             if (containsAny(lower, new List<String>{ 'change expiry', 'update expiry', 'set expiry',
//                     'extend expiry', 'change deadline', 'update message', 'change message',
//                     'set deadline' })) {
//                 return previewUpdateAgreement(extractName(message), extractDate(message), extractMessage(message));
//             }
//
//             // 5. ADD SIGNER
//             if (containsAny(lower, new List<String>{ 'add signer', 'add a signer', 'add signor',
//                     'invite signer', 'add as signer', 'add approver' })) {
//                 return previewAddSigner(
//                     extractName(message),
//                     extractEmail(message),
//                     extractSignerName(message),
//                     extractRole(message)
//                 );
//             }
//
//             // 6. REMOVE SIGNER
//             if (containsAny(lower, new List<String>{ 'remove signer', 'remove the signer',
//                     'delete signer', 'take out signer' })) {
//                 return previewRemoveSigner(
//                     extractName(message),
//                     extractEmail(message)
//                 );
//             }
//
//             // 7. CREATE AGREEMENT (simple form — needs name + type)
//             if (containsAny(lower, new List<String>{ 'create agreement', 'new agreement', 'make agreement',
//                     'create nda', 'create msa', 'create sow', 'create draft' })) {
//                 return previewCreateAgreement(
//                     extractAgreementNameForCreate(message),
//                     extractAgreementType(message)
//                 );
//             }
//
//             // 8. GENERATE DOCUMENT (from template)
//             if (containsAny(lower, new List<String>{ 'generate document', 'generate doc',
//                     'create document from template', 'generate from template' })) {
//                 return previewGenerateDocument(extractTemplateName(message));
//             }
//
//             // ════════════════════════════════════════════════════════════
//             // READ OPERATIONS — execute directly (no confirmation needed)
//             // ════════════════════════════════════════════════════════════
//
//             if (lower.contains('pending') || lower.contains('waiting') || lower.contains('awaiting')) {
//                 return listPending(10);
//             }
//             if (lower.contains('template')) {
//                 return listTemplates(null);
//             }
//             if (lower.contains('audit') || lower.contains('history') || lower.contains('trail')) {
//                 String name = extractName(message);
//                 if (String.isBlank(name)) {
//                     return 'Please tell me which agreement\'s audit trail you want. For example: "Show audit trail for Acme NDA".';
//                 }
//                 return getAuditTrail(null, name, 10);
//             }
//             if (lower.contains('verify') || lower.contains('tamper') || lower.contains('hash')) {
//                 String name = extractName(message);
//                 if (String.isBlank(name)) {
//                     return 'Please tell me which agreement to verify. For example: "Verify Acme NDA".';
//                 }
//                 return verifyHash(null, name);
//             }
//             if (lower.contains('find') || lower.contains('search')) {
//                 return searchAgreements(message, 10);
//             }
//
//             // Default: look up status
//             String name = extractName(message);
//             if (String.isBlank(name)) {
//                 return 'I\'m not sure what you\'re asking. Try: "What\'s the status of [agreement]?", '
//                     + '"Send [agreement] for signature", or "What\'s pending?"';
//             }
//             return getStatus(null, name);
//         } catch (Exception e) {
//             return 'Sorry, I hit an issue: ' + e.getMessage();
//         }
//     }
//
//
//     // ════════════════════════════════════════════════════════════════════
//     //  PREVIEW METHODS — describe what will happen, return JSON payload
//     //  that the LWC sends back via confirmLastAction(...) on "yes".
//     //
//     //  Each preview returns:
//     //    "<human description>\n\n__PENDING__:{\"intent\":\"X\",...}"
//     //
//     //  The LWC parses __PENDING__: marker, stores the JSON, hides the marker
//     //  from the user, and shows only the human description. On "yes", LWC
//     //  calls confirmLastAction(pendingJson).
//     // ════════════════════════════════════════════════════════════════════
//
//     private static String previewSendForSignature(String agreementName) {
//         try {
//             if (String.isBlank(agreementName)) {
//                 return 'Which agreement should I send? For example: "Send Acme NDA for signature".';
//             }
//             Agreement__c agr = findOneAgreement(agreementName);
//             if (agr == null) return 'No agreement matches "' + agreementName + '".';
//             if (agr.Status__c != 'Draft') {
//                 return 'Agreement "' + agr.Name + '" is currently ' + agr.Status__c
//                     + ', not Draft — I can only send draft agreements for signature.';
//             }
//             Integer signerCount = [SELECT COUNT() FROM Signer__c WHERE Agreement__c = :agr.Id];
//             if (signerCount == 0) {
//                 return 'Agreement "' + agr.Name + '" has no signers yet. Add signers before sending.';
//             }
//             String payload = '{"intent":"sendForSignature","agreementId":"' + agr.Id + '","agreementName":"' + escape(agr.Name) + '"}';
//             return 'Ready to send "' + agr.Name + '" for signature.\n'
//                 + 'Status: Draft → Sent\n'
//                 + 'Signers: ' + signerCount + ' will receive signing emails.\n'
//                 + 'Reply "yes" to confirm or "no" to cancel.'
//                 + '\n__PENDING__:' + payload;
//         } catch (Exception e) {
//             return 'Sorry, I hit an issue: ' + e.getMessage();
//         }
//     }
//
//     private static String previewVoidAgreement(String agreementName, String reason) {
//         try {
//             if (String.isBlank(agreementName)) {
//                 return 'Which agreement should I void? For example: "Void Acme NDA, customer withdrew".';
//             }
//             Agreement__c agr = findOneAgreement(agreementName);
//             if (agr == null) return 'No agreement matches "' + agreementName + '".';
//             if (agr.Status__c == 'Voided' || agr.Status__c == 'Completed') {
//                 return 'Agreement "' + agr.Name + '" is already ' + agr.Status__c + '.';
//             }
//             String finalReason = String.isBlank(reason) ? 'Cancelled via voice assistant' : reason;
//             String payload = '{"intent":"voidAgreement","agreementId":"' + agr.Id + '","agreementName":"' + escape(agr.Name) + '","reason":"' + escape(finalReason) + '"}';
//             return 'Ready to VOID "' + agr.Name + '".\n'
//                 + 'Status: ' + agr.Status__c + ' → Voided (irreversible)\n'
//                 + 'Reason: ' + finalReason + '\n'
//                 + 'Reply "yes" to confirm or "no" to cancel.'
//                 + '\n__PENDING__:' + payload;
//         } catch (Exception e) {
//             return 'Sorry, I hit an issue: ' + e.getMessage();
//         }
//     }
//
//     private static String previewSendReminders(String agreementName) {
//         try {
//             if (String.isBlank(agreementName)) {
//                 return 'Which agreement\'s signers should I remind? For example: "Send reminders for Acme NDA".';
//             }
//             Agreement__c agr = findOneAgreement(agreementName);
//             if (agr == null) return 'No agreement matches "' + agreementName + '".';
//             Integer pendingSigners = [SELECT COUNT() FROM Signer__c WHERE Agreement__c = :agr.Id AND Status__c = 'Pending'];
//             if (pendingSigners == 0) {
//                 return 'No pending signers on "' + agr.Name + '" — all signers have responded.';
//             }
//             String payload = '{"intent":"sendReminders","agreementId":"' + agr.Id + '","agreementName":"' + escape(agr.Name) + '"}';
//             return 'Ready to remind ' + pendingSigners + ' pending signer(s) on "' + agr.Name + '".\n'
//                 + 'They will receive a reminder email immediately.\n'
//                 + 'Reply "yes" to confirm or "no" to cancel.'
//                 + '\n__PENDING__:' + payload;
//         } catch (Exception e) {
//             return 'Sorry, I hit an issue: ' + e.getMessage();
//         }
//     }
//
//     private static String previewUpdateAgreement(String agreementName, Date newExpiry, String newMessage) {
//         try {
//             if (String.isBlank(agreementName)) {
//                 return 'Which agreement should I update? For example: "Set Acme NDA expiry to 2026-06-30".';
//             }
//             if (newExpiry == null && String.isBlank(newMessage)) {
//                 return 'What would you like to change on "' + agreementName + '"? Specify expiry date (YYYY-MM-DD) or new message.';
//             }
//             Agreement__c agr = findOneAgreement(agreementName);
//             if (agr == null) return 'No agreement matches "' + agreementName + '".';
//
//             List<String> changes = new List<String>();
//             if (newExpiry != null) changes.add('Expiry: ' + (agr.Expiry_Date__c == null ? 'none' : String.valueOf(agr.Expiry_Date__c)) + ' → ' + String.valueOf(newExpiry));
//             if (String.isNotBlank(newMessage)) changes.add('Message: updated');
//
//             String expiryStr = newExpiry == null ? 'null' : ('"' + String.valueOf(newExpiry) + '"');
//             String msgStr = String.isBlank(newMessage) ? 'null' : ('"' + escape(newMessage) + '"');
//             String payload = '{"intent":"updateAgreement","agreementId":"' + agr.Id + '","agreementName":"' + escape(agr.Name) + '","expiryDate":' + expiryStr + ',"message":' + msgStr + '}';
//             return 'Ready to update "' + agr.Name + '":\n'
//                 + String.join(changes, '\n') + '\n'
//                 + 'Reply "yes" to confirm or "no" to cancel.'
//                 + '\n__PENDING__:' + payload;
//         } catch (Exception e) {
//             return 'Sorry, I hit an issue: ' + e.getMessage();
//         }
//     }
//
//     private static String previewAddSigner(String agreementName, String email, String signerName, String role) {
//         try {
//             if (String.isBlank(agreementName)) {
//                 return 'Which agreement? Try: "Add john@acme.com as signer to Acme NDA".';
//             }
//             if (String.isBlank(email)) {
//                 return 'I need the signer\'s email. Try: "Add [name] [email@example.com] as signer to ' + agreementName + '".';
//             }
//             Agreement__c agr = findOneAgreement(agreementName);
//             if (agr == null) return 'No agreement matches "' + agreementName + '".';
//
//             String finalRole = String.isBlank(role) ? 'Signer' : role;
//             String finalName = String.isBlank(signerName) ? email : signerName;
//             String payload = '{"intent":"addSigner","agreementId":"' + agr.Id + '","agreementName":"' + escape(agr.Name) + '","email":"' + escape(email) + '","signerName":"' + escape(finalName) + '","role":"' + escape(finalRole) + '"}';
//             return 'Ready to add signer to "' + agr.Name + '":\n'
//                 + 'Name: ' + finalName + '\n'
//                 + 'Email: ' + email + '\n'
//                 + 'Role: ' + finalRole + '\n'
//                 + 'Reply "yes" to confirm or "no" to cancel.'
//                 + '\n__PENDING__:' + payload;
//         } catch (Exception e) {
//             return 'Sorry, I hit an issue: ' + e.getMessage();
//         }
//     }
//
//     private static String previewRemoveSigner(String agreementName, String email) {
//         try {
//             if (String.isBlank(agreementName)) {
//                 return 'Which agreement? Try: "Remove john@acme.com from Acme NDA".';
//             }
//             if (String.isBlank(email)) {
//                 return 'I need the signer\'s email to remove. Try: "Remove [email] from ' + agreementName + '".';
//             }
//             Agreement__c agr = findOneAgreement(agreementName);
//             if (agr == null) return 'No agreement matches "' + agreementName + '".';
//
//             String payload = '{"intent":"removeSigner","agreementId":"' + agr.Id + '","agreementName":"' + escape(agr.Name) + '","email":"' + escape(email) + '"}';
//             return 'Ready to remove signer from "' + agr.Name + '":\n'
//                 + 'Email: ' + email + '\n'
//                 + 'Reply "yes" to confirm or "no" to cancel.'
//                 + '\n__PENDING__:' + payload;
//         } catch (Exception e) {
//             return 'Sorry, I hit an issue: ' + e.getMessage();
//         }
//     }
//
//     private static String previewCreateAgreement(String name, String agreementType) {
//         try {
//             if (String.isBlank(name)) {
//                 return 'What should the agreement be named? Try: "Create new NDA called Acme Q4 2026".';
//             }
//             String finalType = String.isBlank(agreementType) ? 'NDA' : agreementType;
//             String payload = '{"intent":"createAgreement","name":"' + escape(name) + '","agreementType":"' + escape(finalType) + '"}';
//             return 'Ready to create a new agreement:\n'
//                 + 'Name: ' + name + '\n'
//                 + 'Type: ' + finalType + '\n'
//                 + 'Status: Draft (will need document upload and signers next)\n'
//                 + 'Reply "yes" to confirm or "no" to cancel.'
//                 + '\n__PENDING__:' + payload;
//         } catch (Exception e) {
//             return 'Sorry, I hit an issue: ' + e.getMessage();
//         }
//     }
//
//     private static String previewGenerateDocument(String templateName) {
//         // Generate document needs a template + record context. From voice alone we
//         // can't pick a target record reliably, so we point the user to the UI.
//         return 'Generating a document needs a target record. Please open the record in SignForce and use the Generate Document button. I can list templates: just ask "show templates".';
//     }
//
//
//     // ════════════════════════════════════════════════════════════════════
//     //  CONFIRM — Execute the pending action after user replies "yes"
//     //  The LWC sends back the JSON payload it stored from the preview.
//     // ════════════════════════════════════════════════════════════════════
//
//     @AuraEnabled
//     public static String confirmLastAction(String pendingJson) {
//         try {
//             if (String.isBlank(pendingJson)) {
//                 return 'Nothing pending to confirm.';
//             }
//             Map<String, Object> p = (Map<String, Object>) JSON.deserializeUntyped(pendingJson);
//             String intent = (String) p.get('intent');
//             if (String.isBlank(intent)) return 'Pending action has no intent — cancelled.';
//
//             if (intent == 'sendForSignature') {
//                 String agrId = (String) p.get('agreementId');
//                 AgreementController.sendForSignature(agrId);
//                 return 'Done. "' + p.get('agreementName') + '" has been sent for signature.';
//             }
//             if (intent == 'voidAgreement') {
//                 String agrId = (String) p.get('agreementId');
//                 String reason = (String) p.get('reason');
//                 AgreementService.voidAgreement(agrId, reason);
//                 return 'Done. "' + p.get('agreementName') + '" has been voided.';
//             }
//             if (intent == 'sendReminders') {
//                 String agrId = (String) p.get('agreementId');
//                 Integer sent = 0;
//                 for (Signer__c s : [SELECT Id FROM Signer__c WHERE Agreement__c = :agrId AND Status__c = 'Pending']) {
//                     AgreementService.sendReminderEmail(s.Id);
//                     sent++;
//                 }
//                 return 'Done. Sent reminders to ' + sent + ' pending signer(s) of "' + p.get('agreementName') + '".';
//             }
//             if (intent == 'updateAgreement') {
//                 String agrId = (String) p.get('agreementId');
//                 Agreement__c agr = [SELECT Id, Expiry_Date__c, Message_to_Signers__c FROM Agreement__c WHERE Id = :agrId LIMIT 1];
//                 Object exp = p.get('expiryDate');
//                 if (exp != null) agr.Expiry_Date__c = Date.valueOf((String) exp);
//                 Object msg = p.get('message');
//                 if (msg != null) agr.Message_to_Signers__c = (String) msg;
//                 update agr;
//                 return 'Done. "' + p.get('agreementName') + '" updated.';
//             }
//             if (intent == 'addSigner') {
//                 String agrId = (String) p.get('agreementId');
//                 Signer__c s = new Signer__c();
//                 s.Agreement__c = agrId;
//                 s.Email__c = (String) p.get('email');
//                 s.Name = (String) p.get('signerName');
//                 s.Role__c = (String) p.get('role');
//                 insert s;
//                 return 'Done. Added signer ' + s.Email__c + ' to "' + p.get('agreementName') + '".';
//             }
//             if (intent == 'removeSigner') {
//                 String agrId = (String) p.get('agreementId');
//                 String email = (String) p.get('email');
//                 List<Signer__c> existing = [SELECT Id FROM Signer__c WHERE Agreement__c = :agrId AND Email__c = :email LIMIT 1];
//                 if (existing.isEmpty()) return 'No signer with email "' + email + '" found on that agreement.';
//                 delete existing;
//                 return 'Done. Removed signer ' + email + ' from "' + p.get('agreementName') + '".';
//             }
//             if (intent == 'createAgreement') {
//                 String name = (String) p.get('name');
//                 String agrType = (String) p.get('agreementType');
//                 Agreement__c agr = new Agreement__c();
//                 agr.Name = name;
//                 agr.Agreement_Type__c = agrType;
//                 agr.Status__c = 'Draft';
//                 insert agr;
//                 return 'Done. Created agreement "' + name + '" (Status: Draft, Type: ' + agrType + '). Upload a document and add signers next.';
//             }
//             return 'Unknown action intent: ' + intent;
//         } catch (Exception e) {
//             return 'Sorry, the action failed: ' + e.getMessage();
//         }
//     }
//
//
//     // ════════════════════════════════════════════════════════════════════
//     //  ENTITY EXTRACTORS — pull structured data from natural-language text
//     // ════════════════════════════════════════════════════════════════════
//
//     private static Boolean containsAny(String haystack, List<String> needles) {
//         if (String.isBlank(haystack)) return false;
//         for (String n : needles) {
//             if (haystack.contains(n)) return true;
//         }
//         return false;
//     }
//
//     private static String extractEmail(String text) {
//         if (String.isBlank(text)) return null;
//         // Simple email regex match
//         Matcher m = Pattern.compile('[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}').matcher(text);
//         if (m.find()) return m.group();
//         return null;
//     }
//
//     private static Date extractDate(String text) {
//         if (String.isBlank(text)) return null;
//         // Match YYYY-MM-DD
//         Matcher m1 = Pattern.compile('\\d{4}-\\d{2}-\\d{2}').matcher(text);
//         if (m1.find()) {
//             try { return Date.valueOf(m1.group()); } catch (Exception e) {}
//         }
//         // Match "next Friday/Monday/etc."
//         String lower = text.toLowerCase();
//         Map<String, Integer> dows = new Map<String, Integer>{
//             'sunday' => 1, 'monday' => 2, 'tuesday' => 3, 'wednesday' => 4,
//             'thursday' => 5, 'friday' => 6, 'saturday' => 7
//         };
//         for (String dow : dows.keySet()) {
//             if (lower.contains('next ' + dow) || lower.contains('this ' + dow)) {
//                 Date today = Date.today();
//                 Date d = today.addDays(1);
//                 Integer targetDow = dows.get(dow);
//                 while (true) {
//                     Datetime dt = Datetime.newInstance(d, Time.newInstance(0,0,0,0));
//                     String dayName = dt.format('EEEE').toLowerCase();
//                     if (dayName == dow) return d;
//                     d = d.addDays(1);
//                     if (d.daysBetween(today) < -14) break;
//                 }
//             }
//         }
//         // Match "in N days"
//         Matcher m2 = Pattern.compile('in (\\d+) days?').matcher(lower);
//         if (m2.find()) {
//             try { return Date.today().addDays(Integer.valueOf(m2.group(1))); } catch (Exception e) {}
//         }
//         return null;
//     }
//
//     private static String extractReason(String text) {
//         if (String.isBlank(text)) return null;
//         String lower = text.toLowerCase();
//         List<String> markers = new List<String>{ ', because ', ' because ', ', reason ', ' reason: ',
//                                                   ', ', ' — ', ' - ' };
//         for (String marker : markers) {
//             Integer idx = lower.indexOf(marker);
//             if (idx >= 0) {
//                 String reason = text.substring(idx + marker.length()).trim().replace('?', '').replace('.', '');
//                 if (reason.length() > 4 && reason.length() < 200) return reason;
//             }
//         }
//         return null;
//     }
//
//     private static String extractRole(String text) {
//         if (String.isBlank(text)) return null;
//         String lower = text.toLowerCase();
//         if (lower.contains('approver') || lower.contains('approval')) return 'Approver';
//         if (lower.contains('cc') || lower.contains('copy')) return 'CC';
//         if (lower.contains('signer')) return 'Signer';
//         return null;
//     }
//
//     private static String extractSignerName(String text) {
//         if (String.isBlank(text)) return null;
//         // Try patterns like "add John Smith as signer" or "add John Smith email"
//         Matcher m = Pattern.compile('(?i)add\\s+([A-Z][a-zA-Z]+(?:\\s+[A-Z][a-zA-Z]+)?)').matcher(text);
//         if (m.find()) {
//             String candidate = m.group(1).trim();
//             if (candidate.length() > 1 && !candidate.toLowerCase().contains('signer')
//                 && !candidate.toLowerCase().contains('approver')) {
//                 return candidate;
//             }
//         }
//         return null;
//     }
//
//     private static String extractMessage(String text) {
//         if (String.isBlank(text)) return null;
//         // Look for "message: ..." or "with message ..."
//         Matcher m = Pattern.compile('(?i)(?:message|note)\\s*[:=]\\s*([^"]+)').matcher(text);
//         if (m.find()) return m.group(1).trim();
//         return null;
//     }
//
//     private static String extractAgreementType(String text) {
//         if (String.isBlank(text)) return null;
//         String upper = text.toUpperCase();
//         for (String t : new List<String>{ 'NDA', 'MSA', 'SOW', 'CONTRACT', 'EMPLOYMENT' }) {
//             if (upper.contains(t)) return t == 'CONTRACT' ? 'Sales Contract' : (t == 'EMPLOYMENT' ? 'Employment' : t);
//         }
//         return null;
//     }
//
//     private static String extractAgreementNameForCreate(String text) {
//         if (String.isBlank(text)) return null;
//         // Look for "called X" or "named X" or "for X"
//         Matcher m1 = Pattern.compile('(?i)(?:called|named)\\s+([\\w\\s-]+?)(?:\\s+for|\\s+with|\\?|\\.|$)').matcher(text);
//         if (m1.find()) return m1.group(1).trim();
//         Matcher m2 = Pattern.compile('(?i)create\\s+(?:new\\s+)?(?:\\w+\\s+)?for\\s+([\\w\\s-]+?)(?:\\s+with|\\?|\\.|$)').matcher(text);
//         if (m2.find()) return m2.group(1).trim();
//         return null;
//     }
//
//     private static String extractTemplateName(String text) {
//         if (String.isBlank(text)) return null;
//         Matcher m = Pattern.compile('(?i)(?:template|using)\\s+([\\w\\s-]+?)(?:\\?|\\.|$)').matcher(text);
//         if (m.find()) return m.group(1).trim();
//         return null;
//     }
//
//     private static Agreement__c findOneAgreement(String agreementName) {
//         String term = '%' + String.escapeSingleQuotes(agreementName.trim()) + '%';
//         List<Agreement__c> rows = [
//             SELECT Id, Name, Status__c, Expiry_Date__c, Message_to_Signers__c, Agreement_Type__c
//             FROM Agreement__c
//             WHERE Name LIKE :term
//             WITH SECURITY_ENFORCED
//             ORDER BY LastModifiedDate DESC
//             LIMIT 1
//         ];
//         return rows.isEmpty() ? null : rows[0];
//     }
//
//     private static String escape(String s) {
//         if (s == null) return '';
//         return s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', ' ').replace('\r', ' ');
//     }
//
//     private static String extractName(String text) {
//         if (String.isBlank(text)) return text;
//         String cleaned = text.replace('?', '').replace('.', '').trim();
//         List<String> markers = new List<String>{' status of ', ' status for ', ' audit trail for ', ' history for ', ' verify ', ' find ', ' search '};
//         String lower = cleaned.toLowerCase();
//         for (String marker : markers) {
//             Integer idx = lower.indexOf(marker);
//             if (idx >= 0) return cleaned.substring(idx + marker.length()).trim();
//         }
//         return cleaned;
//     }
//
//     @AuraEnabled
//     public static String createTemplate(String name, String objectApiName, String contentVersionId, String outputFormat, Boolean active, Boolean autoCreateAgreement, String defaultAgreementType, String description) {
//         try {
//             Id id = TemplateService.registerTemplate(null, name, objectApiName, contentVersionId, outputFormat, null, active == null ? true : active, autoCreateAgreement == true, defaultAgreementType, description);
//             return 'Template "' + name + '" was created. Record Id: ' + id;
//         } catch (Exception e) {
//             throw new AuraHandledException(e.getMessage());
//         }
//     }
//
//     @AuraEnabled
//     public static String createAgreement(String name, String agreementType, String signingOrder, String message, Date expiryDate) {
//         try {
//             DateTime expiry = expiryDate == null ? null : DateTime.newInstance(expiryDate, Time.newInstance(23, 59, 0, 0));
//             Agreement__c agr = AgreementService.createAgreement(
//                 String.isBlank(name) ? 'New Agreement' : name,
//                 String.isBlank(agreementType) ? 'Standard' : agreementType,
//                 String.isBlank(signingOrder) ? 'Parallel' : signingOrder,
//                 message,
//                 expiry
//             );
//             return 'Draft agreement "' + agr.Name + '" was created. Record Id: ' + agr.Id;
//         } catch (Exception e) {
//             throw new AuraHandledException(e.getMessage());
//         }
//     }
//
//     @AuraEnabled
//     public static String uploadDocument(String agreementId, String fileName, String pdfBase64, Decimal fileSize) {
//         try {
//             Id docId = AgreementController.uploadTier1Document(toId(agreementId, 'Agreement Id'), fileName, pdfBase64, fileSize);
//             return 'Document "' + (String.isBlank(fileName) ? 'Document.pdf' : fileName) + '" was uploaded. Record Id: ' + docId;
//         } catch (Exception e) {
//             throw new AuraHandledException(e.getMessage());
//         }
//     }
//
//     @AuraEnabled
//     public static String generateDocument(String templateId, String recordId) {
//         try {
//             DocumentGenerationService.GenerationResult result = DocumentGenerationService.generate(toId(templateId, 'Template Id'), toId(recordId, 'Record Id'));
//             String fileId = result.contentVersionId != null ? String.valueOf(result.contentVersionId) : String.valueOf(result.contentDocumentId);
//             return 'Document generation finished with status ' + result.status + '. File: ' + result.filename + '. Record Id: ' + fileId;
//         } catch (Exception e) {
//             throw new AuraHandledException(e.getMessage());
//         }
//     }
//
//     @AuraEnabled
//     public static String addSigner(String agreementId, String agreementName, String signerName, String email, String role, Integer signingOrder) {
//         try {
//             Agreement__c agr = findAgreement(agreementId, agreementName);
//             Id signerId = AgreementController.addSigner(agr.Id, signerName, email, String.isBlank(role) ? 'Signer' : role, signingOrder == null ? 1 : signingOrder);
//             return 'Added ' + email + ' as a ' + (String.isBlank(role) ? 'Signer' : role) + ' to "' + agr.Name + '". Record Id: ' + signerId;
//         } catch (Exception e) {
//             throw new AuraHandledException(e.getMessage());
//         }
//     }
//
//     @AuraEnabled
//     public static String removeSigner(String signerId, String agreementId, String agreementName, String email) {
//         try {
//             Id idToDelete;
//             if (String.isNotBlank(signerId)) {
//                 idToDelete = toId(signerId, 'Signer Id');
//             } else {
//                 Agreement__c agr = findAgreement(agreementId, agreementName);
//                 List<Signer__c> rows = [
//                     SELECT Id, Email__c
//                     FROM Signer__c
//                     WHERE Agreement__c = :agr.Id AND Email__c = :email
//                     WITH SECURITY_ENFORCED
//                     LIMIT 2
//                 ];
//                 if (rows.isEmpty()) throw new AuraHandledException('No signer found for ' + email + '.');
//                 if (rows.size() > 1) throw new AuraHandledException('Multiple matching signers found. Please provide the signer Id.');
//                 idToDelete = rows[0].Id;
//             }
//             AgreementController.deleteSigner(idToDelete);
//             return 'Signer was removed. Record Id: ' + idToDelete;
//         } catch (Exception e) {
//             throw new AuraHandledException(e.getMessage());
//         }
//     }
//
//     @AuraEnabled
//     public static String updateAgreement(String agreementId, String agreementName, String newName, Date expiryDate, String message) {
//         try {
//             Agreement__c agr = findAgreement(agreementId, agreementName);
//             Agreement__c updateRow = new Agreement__c(Id = agr.Id);
//             Boolean changed = false;
//             if (String.isNotBlank(newName)) { updateRow.Name = newName; changed = true; }
//             if (expiryDate != null) { updateRow.Expiry_Date__c = DateTime.newInstance(expiryDate, Time.newInstance(23, 59, 0, 0)); changed = true; }
//             if (message != null) { updateRow.Message_to_Signers__c = message; changed = true; }
//             if (!changed) return 'No updates were provided for "' + agr.Name + '".';
//             update updateRow;
//             return 'Agreement "' + agr.Name + '" was updated. Record Id: ' + agr.Id;
//         } catch (Exception e) {
//             throw new AuraHandledException(e.getMessage());
//         }
//     }
//
//     @AuraEnabled
//     public static String sendForSignature(String agreementId, String agreementName) {
//         try {
//             Agreement__c agr = findAgreement(agreementId, agreementName);
//             AgreementController.sendForSignature(agr.Id);
//             return 'Agreement "' + agr.Name + '" was sent for signature.';
//         } catch (Exception e) {
//             throw new AuraHandledException(e.getMessage());
//         }
//     }
//
//     @AuraEnabled(cacheable=true)
//     public static String getStatus(String agreementId, String agreementName) {
//         try {
//             // Custom inline lookup (instead of findAgreement) so we can list
//             // multiple matches as text instead of throwing.
//             Agreement__c agr;
//             if (String.isNotBlank(agreementId)) {
//                 List<Agreement__c> byId = [
//                     SELECT Id, Name, Status__c, Expiry_Date__c, Message_to_Signers__c,
//                            Agreement_Type__c, Signing_Order__c
//                     FROM Agreement__c
//                     WHERE Id = :toId(agreementId, 'Agreement Id')
//                     WITH SECURITY_ENFORCED
//                     LIMIT 1
//                 ];
//                 if (byId.isEmpty()) {
//                     return 'No agreement found with that Id.';
//                 }
//                 agr = byId[0];
//             } else {
//                 if (String.isBlank(agreementName)) {
//                     return 'Please tell me which agreement to check. For example: "What\'s the status of Acme NDA?"';
//                 }
//                 String term = '%' + String.escapeSingleQuotes(agreementName.trim()) + '%';
//                 List<Agreement__c> rows = [
//                     SELECT Id, Name, Status__c, Expiry_Date__c, Message_to_Signers__c,
//                            Agreement_Type__c, Signing_Order__c
//                     FROM Agreement__c
//                     WHERE Name LIKE :term
//                     WITH SECURITY_ENFORCED
//                     ORDER BY LastModifiedDate DESC
//                     LIMIT 5
//                 ];
//                 if (rows.isEmpty()) {
//                     return 'I could not find any agreement matching "' + agreementName + '". Please check the name and try again.';
//                 }
//                 if (rows.size() > 1) {
//                     // Multiple matches — return a list instead of throwing.
//                     List<String> names = new List<String>();
//                     for (Agreement__c r : rows) {
//                         names.add(r.Name + ' (' + r.Status__c + ')');
//                     }
//                     return 'I found ' + rows.size() + ' agreements matching "' + agreementName + '": '
//                         + String.join(names, '; ')
//                         + '. Which one did you mean?';
//                 }
//                 agr = rows[0];
//             }
//
//             List<Signer__c> signers = [
//                 SELECT Name, Email__c, Role__c, Status__c
//                 FROM Signer__c
//                 WHERE Agreement__c = :agr.Id
//                 WITH SECURITY_ENFORCED
//                 ORDER BY Signing_Order__c ASC NULLS LAST, CreatedDate ASC
//                 LIMIT 20
//             ];
//             List<String> signerBits = new List<String>();
//             for (Signer__c s : signers) signerBits.add((String.isBlank(s.Name) ? s.Email__c : s.Name + ' <' + s.Email__c + '>') + ': ' + s.Status__c);
//             String signerText = signerBits.isEmpty() ? 'No signers yet.' : String.join(signerBits, '; ');
//             return '"' + agr.Name + '" is ' + agr.Status__c + '. Expiry: ' + dateTimeText(agr.Expiry_Date__c) + '. Signers: ' + signerText;
//         } catch (Exception e) {
//             return 'Sorry, I hit an issue: ' + e.getMessage();
//         }
//     }
//
//     @AuraEnabled(cacheable=true)
//     public static String listPending(Integer maxResults) {
//         Integer limitSize = maxResults == null || maxResults <= 0 ? 10 : Math.min(maxResults, 50);
//         List<Agreement__c> rows = [
//             SELECT Id, Name, Status__c, Expiry_Date__c
//             FROM Agreement__c
//             WHERE Status__c IN ('Draft','Sent','Pending','In Progress')
//             WITH SECURITY_ENFORCED
//             ORDER BY LastModifiedDate DESC
//             LIMIT :limitSize
//         ];
//         if (rows.isEmpty()) return 'No pending agreements found.';
//         List<String> bits = new List<String>();
//         for (Agreement__c a : rows) bits.add(a.Name + ' (' + a.Status__c + ', expires ' + dateTimeText(a.Expiry_Date__c) + ')');
//         return 'Pending agreements: ' + String.join(bits, '; ');
//     }
//
//     @AuraEnabled(cacheable=true)
//     public static String searchAgreements(String searchTerm, Integer maxResults) {
//         if (String.isBlank(searchTerm)) return 'Please provide a search term.';
//         Integer limitSize = maxResults == null || maxResults <= 0 ? 10 : Math.min(maxResults, 50);
//         String term = '%' + String.escapeSingleQuotes(searchTerm.trim()) + '%';
//         Map<Id, Agreement__c> found = new Map<Id, Agreement__c>([
//             SELECT Id, Name, Status__c, Expiry_Date__c
//             FROM Agreement__c
//             WHERE Name LIKE :term
//             WITH SECURITY_ENFORCED
//             ORDER BY LastModifiedDate DESC
//             LIMIT :limitSize
//         ]);
//         for (Signer__c s : [
//             SELECT Agreement__c, Agreement__r.Name, Agreement__r.Status__c, Agreement__r.Expiry_Date__c
//             FROM Signer__c
//             WHERE Email__c LIKE :term OR Name LIKE :term
//             WITH SECURITY_ENFORCED
//             ORDER BY LastModifiedDate DESC
//             LIMIT :limitSize
//         ]) {
//             if (s.Agreement__c != null && !found.containsKey(s.Agreement__c)) {
//                 found.put(s.Agreement__c, new Agreement__c(Id = s.Agreement__c, Name = s.Agreement__r.Name, Status__c = s.Agreement__r.Status__c, Expiry_Date__c = s.Agreement__r.Expiry_Date__c));
//             }
//         }
//         if (found.isEmpty()) return 'No agreements found matching "' + searchTerm + '".';
//         List<String> bits = new List<String>();
//         for (Agreement__c a : found.values()) bits.add(a.Name + ' (' + a.Status__c + ')');
//         return 'Found agreements: ' + String.join(bits, '; ');
//     }
//
//     @AuraEnabled(cacheable=true)
//     public static String listTemplates(String objectApiName) {
//         List<Document_Template__c> rows = String.isBlank(objectApiName)
//             ? [SELECT Id, Name, Object_API_Name__c, Output_Format__c, Active__c, Auto_Create_Agreement__c FROM Document_Template__c WHERE Active__c = true WITH SECURITY_ENFORCED ORDER BY Name ASC LIMIT 50]
//             : TemplateService.getEligibleTemplates(objectApiName);
//         if (rows.isEmpty()) return 'No active templates found.';
//         List<String> bits = new List<String>();
//         for (Document_Template__c t : rows) bits.add(t.Name + ' (' + t.Output_Format__c + ')');
//         return 'Available templates: ' + String.join(bits, '; ');
//     }
//
//     @AuraEnabled
//     public static String sendReminders(String agreementId, String agreementName) {
//         try {
//             Agreement__c agr = findAgreement(agreementId, agreementName);
//             AgreementController.sendForSignatureWithCustomEmail(agr.Id, 'Reminder: Please sign "' + agr.Name + '"', 'This is a reminder to review and sign the agreement.');
//             return 'Reminder emails were sent for "' + agr.Name + '".';
//         } catch (Exception e) {
//             throw new AuraHandledException(e.getMessage());
//         }
//     }
//
//     @AuraEnabled
//     public static String voidAgreement(String agreementId, String agreementName, String reason) {
//         try {
//             Agreement__c agr = findAgreement(agreementId, agreementName);
//             AgreementController.voidAgreement(agr.Id, String.isBlank(reason) ? 'Voided by SignForce Assistant' : reason);
//             return 'Agreement "' + agr.Name + '" was voided.';
//         } catch (Exception e) {
//             throw new AuraHandledException(e.getMessage());
//         }
//     }
//
//     @AuraEnabled(cacheable=true)
//     public static String verifyHash(String agreementId, String agreementName) {
//         try {
//             Agreement__c agr = findAgreement(agreementId, agreementName);
//             Boolean valid = AgreementController.verifyDocumentHash(agr.Id);
//             return valid ? 'The document hash for "' + agr.Name + '" is valid.' : 'The document hash for "' + agr.Name + '" does not match.';
//         } catch (Exception e) {
//             throw new AuraHandledException(e.getMessage());
//         }
//     }
//
//     @AuraEnabled(cacheable=true)
//     public static String getAuditTrail(String agreementId, String agreementName, Integer maxResults) {
//         try {
//             Agreement__c agr = findAgreement(agreementId, agreementName);
//             Integer limitSize = maxResults == null || maxResults <= 0 ? 10 : Math.min(maxResults, 50);
//             List<Signing_Event__c> rows = [
//                 SELECT Action__c, Signer_Email__c, Event_Timestamp__c, Notes__c
//                 FROM Signing_Event__c
//                 WHERE Agreement__c = :agr.Id
//                 WITH SECURITY_ENFORCED
//                 ORDER BY Event_Timestamp__c DESC
//                 LIMIT :limitSize
//             ];
//             if (rows.isEmpty()) return 'No audit events found for "' + agr.Name + '".';
//             List<String> bits = new List<String>();
//             for (Signing_Event__c e : rows) bits.add(e.Event_Timestamp__c.format() + ': ' + e.Action__c + (String.isBlank(e.Signer_Email__c) ? '' : ' by ' + e.Signer_Email__c));
//             return 'Audit trail for "' + agr.Name + '": ' + String.join(bits, '; ');
//         } catch (Exception e) {
//             throw new AuraHandledException(e.getMessage());
//         }
//     }
// }
}