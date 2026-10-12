/**
 * AgentforceCreateAgreementAction
 * ────────────────────────────────────────────────────────────────────────
 * Invocable Apex action exposed to Agentforce. Lets a user create an
 * Agreement__c record from a voice (or text) command such as:
 *
 *   "Create a new agreement called Q4 Vendor NDA, type NDA, parallel
 *    signing, expires in 30 days, message: Please review and sign."
 *
 * Agentforce parses the natural language utterance into the @InvocableVariable
 * inputs below and calls invoke(). The agent then reads outputs (agreementId,
 * success, message) to confirm back to the user.
 *
 * NOTE: This deliberately does NOT add signers or send the agreement —
 * keep one action = one job. Add separate actions for AddSigner, SendForSig,
 * etc. so the agent can compose them.
 * ────────────────────────────────────────────────────────────────────────
 */
public with sharing class AgentforceCreateAgreementAction {

    // ─── Request wrapper ────────────────────────────────────────────────
    public class Request {
        @InvocableVariable(
            label='Agreement Name'
            description='Name/title of the agreement, e.g. "Q4 Vendor NDA"'
            required=true)
        public String agreementName;

        @InvocableVariable(
            label='Agreement Type'
            description='Type of agreement. Common values: NDA, MSA, SOW, Contract, Offer Letter')
        public String agreementType;

        @InvocableVariable(
            label='Signing Order'
            description='Either "Sequential" or "Parallel". Defaults to Parallel if not specified.')
        public String signingOrder;

        @InvocableVariable(
            label='Message to Signers'
            description='Optional message shown to recipients when the agreement is sent.')
        public String messageToSigners;

        @InvocableVariable(
            label='Expiry Date'
            description='Date the agreement expires. Accept either an absolute date or null.')
        public Date expiryDate;

        @InvocableVariable(
            label='Expires In Days'
            description='Alternative to Expiry Date — number of days from today. Used only if Expiry Date is null.')
        public Integer expiresInDays;
    }

    // ─── Response wrapper ───────────────────────────────────────────────
    public class Response {
        @InvocableVariable(label='Success' description='True if the agreement was created.')
        public Boolean success;

        @InvocableVariable(label='Agreement Id' description='Id of the newly created Agreement__c record.')
        public String agreementId;

        @InvocableVariable(label='Agreement Name' description='Final name stored on the record.')
        public String agreementName;

        @InvocableVariable(label='Confirmation Message'
            description='Human-readable confirmation that the agent will speak back to the user.')
        public String message;
    }

    // ─── Invocable entry point ──────────────────────────────────────────
    @InvocableMethod(
        label='Create Agreement'
        description='Creates a new Agreement__c record. Use when the user asks to create, draft, or start a new agreement.'
        category='SignForce')
    public static List<Response> invoke(List<Request> requests) {
        List<Response> responses = new List<Response>();

        for (Request req : requests) {
            Response res = new Response();
            try {
                validate(req);

                Agreement__c agr = new Agreement__c();
                agr.Name = req.agreementName.trim();
                agr.Agreement_Type__c = normalizeType(req.agreementType);
                agr.Signing_Order__c = normalizeSigningOrder(req.signingOrder);
                agr.Message_to_Signers__c = req.messageToSigners;
                agr.Status__c = 'Draft';
                agr.Is_Template__c = false;
                agr.Storage_Location__c = 'Salesforce';

                Date expiry = resolveExpiry(req.expiryDate, req.expiresInDays);
                if (expiry != null) {
                    agr.Expiry_Date__c = Datetime.newInstance(expiry, Time.newInstance(23, 59, 0, 0));
                }

                // CRUD/FLS check before insert (matches AgreementController pattern)
                if (!Schema.sObjectType.Agreement__c.isCreateable()) {
                    throw new AgentActionException('You do not have permission to create agreements.');
                }
                insert agr;

                res.success = true;
                res.agreementId = agr.Id;
                res.agreementName = agr.Name;
                res.message = buildConfirmation(agr);

            } catch (AgentActionException aex) {
                res.success = false;
                res.message = aex.getMessage();
            } catch (Exception ex) {
                res.success = false;
                res.message = 'Could not create the agreement: ' + ex.getMessage();
                System.debug(LoggingLevel.ERROR, 'AgentforceCreateAgreementAction: ' + ex);
            }
            responses.add(res);
        }
        return responses;
    }

    // ─── Helpers ────────────────────────────────────────────────────────
    private static void validate(Request req) {
        if (req == null || String.isBlank(req.agreementName)) {
            throw new AgentActionException(
                'I need a name for the agreement. What should I call it?');
        }
        if (req.agreementName.length() > 80) {
            throw new AgentActionException(
                'The agreement name is too long. Please keep it under 80 characters.');
        }
    }

    private static String normalizeType(String input) {
        if (String.isBlank(input)) return 'Contract';
        String t = input.trim().toLowerCase();
        if (t.contains('nda') || t.contains('disclosure')) return 'NDA';
        if (t.contains('msa') || t.contains('master service')) return 'MSA';
        if (t.contains('sow') || t.contains('statement of work')) return 'SOW';
        if (t.contains('offer')) return 'Offer Letter';
        return input.trim();
    }

    private static String normalizeSigningOrder(String input) {
        if (String.isBlank(input)) return 'Parallel';
        String t = input.trim().toLowerCase();
        if (t.startsWith('seq') || t.contains('order') || t.contains('one after')) return 'Sequential';
        return 'Parallel';
    }

    private static Date resolveExpiry(Date explicitDate, Integer days) {
        if (explicitDate != null) return explicitDate;
        if (days != null && days > 0) return Date.today().addDays(days);
        return null;
    }

    private static String buildConfirmation(Agreement__c agr) {
        String msg = 'Done. I created "' + agr.Name + '" as a '
            + agr.Agreement_Type__c + ' agreement with '
            + agr.Signing_Order__c + ' signing';
        if (agr.Expiry_Date__c != null) {
            msg += ', expiring on ' + agr.Expiry_Date__c.date().format();
        }
        msg += '. It is in Draft status. Would you like to add signers next?';
        return msg;
    }

    public class AgentActionException extends Exception {}
}