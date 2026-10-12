/**
 * Visualforce controller for the StampedAgreementPDF page — renders the formal
 * signed-agreement PDF with audit trail. Used as email attachment on completion.
 *
 * SHARING: WITHOUT SHARING — System-context VF page rendering. Not @AuraEnabled.
 * Called from server-side stamp flows where the original user's sharing context
 * is not available.
 *
 * SECURITY MODEL:
 *   - All SOQL uses — CRUD/FLS enforced at the statement level.
 *   - No DML in this class (read-only rendering).
 */
public with sharing class StampedAgreementPDFController {

    public String envelopeId    { get; set; }
    public String agreementName { get; set; }
    public String agreementType { get; set; }
    public String sentBy        { get; set; }
    public String completedDate { get; set; }
    public String generatedOn   { get; set; }
    public Boolean hasFieldValues { get; set; }

    public List<SignerRow>  signerWrappers { get; set; }
    public List<FieldRow>   fieldValues    { get; set; }
    public List<AuditRow>   auditRows      { get; set; }

    // Org default timezone, resolved once and cached, so stamped + cert +
    // email timestamps all render in the same local zone (with zone label).
    private static String ORG_TZ;
    private static String orgTz() {
        if (ORG_TZ == null) {
            ORG_TZ = GuestSigningApiInternal.orgTimeZone();
        }
        return ORG_TZ;
    }

    public class SignerRow {
        public String signerName        { get; set; }
        public String signerEmail       { get; set; }
        public String role              { get; set; }
        public Boolean isCC             { get; set; }
        public String signedDate        { get; set; }
        public String certificateId     { get; set; }
        public String ipAddress         { get; set; }
        public Boolean isTyped          { get; set; }
        public Boolean isDrawn          { get; set; }
        public Boolean isUploaded       { get; set; }
        public String typedName         { get; set; }
        public String typedFont         { get; set; }
        public String signatureImageData { get; set; }
    }

    public class FieldRow {
        public String label        { get; set; }
        public String fieldType    { get; set; }
        public String displayValue { get; set; }
    }

    public class AuditRow {
        public String action      { get; set; }
        public String signerEmail { get; set; }
        public String timestamp   { get; set; }
        public String ipAddress   { get; set; }
        public String rowClass    { get; set; }
    }

    public StampedAgreementPDFController() {
        String agreementId = ApexPages.currentPage().getParameters().get('agreementId');
        if (String.isBlank(agreementId)) return;

        Agreement__c agr = GuestSigningApiInternal.stAgreement(agreementId);

        envelopeId    = agr.Envelope_ID__c != null ? agr.Envelope_ID__c : '';
        agreementName = agr.Name;
        agreementType = agr.Agreement_Type__c != null ? agr.Agreement_Type__c : '';
        generatedOn   = DateTime.now().format('MMM dd, yyyy, h:mm a z', orgTz());
        completedDate = agr.Completed_Date__c != null
            ? agr.Completed_Date__c.format('MMM dd, yyyy, h:mm a z', orgTz())
            : DateTime.now().format('MMM dd, yyyy, h:mm a z', orgTz());

        try {
            sentBy = GuestSigningApiInternal.userName(agr.CreatedById)[0].Name;
        } catch(Exception e) {
            sentBy = agr.Owner.Name;
        }

        // ── Build signer rows ──
        List<Signer__c> rawSigners = GuestSigningApiInternal.stSigners(agreementId);

        signerWrappers = new List<SignerRow>();
        for (Signer__c s : rawSigners) {
            SignerRow sr = new SignerRow();
            sr.signerName    = s.Name;
            sr.signerEmail   = s.Email__c;
            sr.role          = s.Role__c;
            // CC / Approver recipients never sign — flag them so the
            // Signatures section shows a "Copy" badge instead of "Signed"
            // and skips the signature/certificate detail (do not present a
            // CC as a signed party).
            sr.isCC          = (s.Role__c == 'CC');
            sr.certificateId = s.Signature_Certificate_ID__c != null ? s.Signature_Certificate_ID__c : '';
            sr.ipAddress     = s.Signing_IP_Address__c != null ? s.Signing_IP_Address__c : '';
            sr.signedDate    = s.Signed_Date__c != null
                ? s.Signed_Date__c.format('MMM dd, yyyy, h:mm a z', orgTz()) : 'Pending';
            sr.isTyped    = false;
            sr.isDrawn    = false;
            sr.isUploaded = false;

            // Get signature field value for this signer
            List<Signature_Field__c> sigFields = GuestSigningApiInternal.stSignatureField(agreementId, s.Id);

            if (!sigFields.isEmpty() && String.isNotBlank(sigFields[0].Field_Value__c)) {
                String val = sigFields[0].Field_Value__c;
                if (val.startsWith('typed:')) {
                    sr.isTyped = true;
                    List<String> parts = val.split(':');
                    sr.typedName = parts.size() > 1 ? parts[1] : s.Name;
                    sr.typedFont = parts.size() > 2 ? parts[2] : 'Dancing Script';
                } else if (val.startsWith('data:image')) {
                    sr.isUploaded = true;
                    sr.signatureImageData = val;
                } else if (val.startsWith('[')) {
                    sr.isDrawn = true;
                }
            } else {
                // Fallback to Saved_Signature__c
                List<Saved_Signature__c> saved = GuestSigningApiInternal.savedSignatureFor(s.Email__c);
                if (!saved.isEmpty() && String.isNotBlank(saved[0].Signature_Data__c)) {
                    String val = saved[0].Signature_Data__c;
                    if (saved[0].Signature_Type__c == 'Type') {
                        sr.isTyped = true;
                        List<String> parts = val.split(':');
                        sr.typedName = parts.size() > 1 ? parts[1] : s.Name;
                        sr.typedFont = parts.size() > 2 ? parts[2] : 'Dancing Script';
                    } else if (saved[0].Signature_Type__c == 'Upload') {
                        sr.isUploaded = true;
                        sr.signatureImageData = val;
                    } else {
                        sr.isDrawn = true;
                    }
                } else {
                    sr.isDrawn = true; // Default — show descriptive text
                }
            }
            signerWrappers.add(sr);
        }

        // ── Build field value rows (non-signature fields) ──
        List<Signature_Field__c> allFields = GuestSigningApiInternal.stValueFields(agreementId);

        fieldValues = new List<FieldRow>();
        for (Signature_Field__c f : allFields) {
            FieldRow fr = new FieldRow();
            fr.label     = f.Field_Label__c;
            fr.fieldType = f.Field_Type__c;
            // Format display value
            if (f.Field_Type__c == 'Checkbox') {
                // U+2611/U+2610 ballot-box glyphs have no font in the VF PDF
                // renderer and show as tofu/X boxes. Use the renderer-safe
                // check mark (U+2713, same as SignedAgreementPDF.page) for
                // true and plain text for false.
                fr.displayValue = f.Field_Value__c == 'true' ? '✓ Checked' : 'Unchecked';
            } else {
                fr.displayValue = f.Field_Value__c != null ? f.Field_Value__c : '';
            }
            fieldValues.add(fr);
        }
        hasFieldValues = !fieldValues.isEmpty();

        // ── Build audit rows ──
        List<Signing_Event__c> events = GuestSigningApiInternal.auditRowsFor(agreementId);

        auditRows = new List<AuditRow>();
        Integer idx = 0;
        for (Signing_Event__c ev : events) {
            AuditRow ar = new AuditRow();
            ar.action      = ev.Action__c != null ? ev.Action__c : '';
            ar.signerEmail = ev.Signer_Email__c != null ? ev.Signer_Email__c : '';
            ar.ipAddress   = ev.IP_Address__c != null ? ev.IP_Address__c : '';
            ar.timestamp   = ev.Event_Timestamp__c != null
                ? ev.Event_Timestamp__c.format('MMM dd, yyyy, h:mm a z', orgTz()) : '';
            ar.rowClass    = Math.mod(idx, 2) == 0 ? 'audit-row-even' : 'audit-row';
            auditRows.add(ar);
            idx++;
        }
    }
}