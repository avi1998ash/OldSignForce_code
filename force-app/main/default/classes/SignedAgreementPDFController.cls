/**
* @description : Controller for Signed Agreement PDF
* @author      : SignForce
**/
public with sharing class SignedAgreementPDFController {
    public Agreement__c agreement { get; set; }
    public List<SignerWrapper> signers { get; set; }
    public List<Signing_Event__c> auditEvents { get; set; }
    public List<AuditRow> auditRows { get; set; }
    public String generatedDate { get; set; }
    public String sentByName { get; set; }
    public String completedDateStr { get; set; }
    public String sentDateStr { get; set; }
    public String tzLabel { get; set; }
    public String tzId { get; set; }
    public Boolean hasData { get; set; }
    public String diagnosticMessage { get; set; }
    public String passedAgreementId { get; set; }
    // CC / Approver recipients never sign — they must NOT inflate the
    // "Total Signers" / "Signatures" stat cards. Count only true signers
    // (Role = 'Signer', or null/legacy). The per-signer CC cards are
    // unaffected and still render with a "CC · Copy" badge.
    public Integer signerCount {
        get {
            if (signers == null) return 0;
            Integer cnt = 0;
            for (SignerWrapper sw : signers) {
                String r = (sw.signer != null) ? sw.signer.Role__c : null;
                if (r == null || r == 'Signer') cnt++;
            }
            return cnt;
        }
    }

    // Org default timezone, resolved once and cached, so cert + stamped +
    // email timestamps all render in the same local zone (with zone label).
    private static String ORG_TZ;
    private static String orgTz() {
        if (ORG_TZ == null) {
            ORG_TZ = GuestSigningApi.orgTimeZone();
        }
        return ORG_TZ;
    }

    // Audit-trail row with the timestamp pre-formatted in the org default
    // timezone (with zone label), so the audit table matches every other
    // cert timestamp instead of rendering raw UTC on the VF page.
    public class AuditRow {
        public String action { get; set; }
        public String signerEmail { get; set; }
        public String timestampStr { get; set; }
        public String ipAddress { get; set; }
    }

    public class SignerWrapper {
        public Signer__c signer { get; set; }
        public String signatureData { get; set; }
        public String signatureType { get; set; }
        public String fontFamily { get; set; }
        public Boolean hasSignature { get; set; }
        public Boolean isDrawSignature { get; set; }
        public Boolean isTypeSignature { get; set; }
        public Boolean isUploadSignature { get; set; }
        public String typedName { get; set; }
        public String typedFont { get; set; }
        public String signedDateStr { get; set; }
        public Boolean isSigned { get; set; }
        public String certificateId { get; set; }
        public String signingIpAddress { get; set; }
    }

    public SignedAgreementPDFController() {
        // Initialize EVERYTHING up-front so the page never binds to a null collection.
        hasData = false;
        diagnosticMessage = '';
        generatedDate = DateTime.now().format('MMM dd, yyyy, h:mm a z', orgTz());
        sentByName = 'SignForce User';
        completedDateStr = DateTime.now().format('MMM dd, yyyy, h:mm a z', orgTz());
        sentDateStr = '-';
        tzId = orgTz();
        tzLabel = DateTime.now().format('z', orgTz());
        signers = new List<SignerWrapper>();
        auditEvents = new List<Signing_Event__c>();
        auditRows = new List<AuditRow>();
        agreement = new Agreement__c();

        String agreementId = ApexPages.currentPage().getParameters().get('agreementId');
        passedAgreementId = agreementId;
        System.debug('SignForce CERT PAGE: constructor called with agreementId=' + agreementId);

        if (String.isBlank(agreementId)) {
            diagnosticMessage = 'No agreementId parameter passed to the page.';
            System.debug(LoggingLevel.ERROR, 'SignForce CERT PAGE: ' + diagnosticMessage);
            return;
        }

        // Safe agreement fetch — Guest User context may not have access
        List<Agreement__c> agrList;
        try {
            agrList = GuestSigningApi.saAgreement(agreementId);
        } catch (Exception qe) {
            diagnosticMessage = 'SOQL on Agreement__c failed: ' + qe.getMessage();
            System.debug(LoggingLevel.ERROR, 'SignForce CERT PAGE: ' + diagnosticMessage);
            return;
        }

        if (agrList == null || agrList.isEmpty()) {
            diagnosticMessage = 'Agreement not visible to this user context for id=' + agreementId;
            System.debug(LoggingLevel.ERROR, 'SignForce CERT PAGE: ' + diagnosticMessage);
            return;
        }
        agreement = agrList[0];
        System.debug('SignForce CERT PAGE: agreement found: ' + agreement.Name);

        // Get owner name safely
        if (agreement.CreatedById != null) {
            try {
                List<User> ownerList = GuestSigningApi.userName(agreement.CreatedById);
                if (!ownerList.isEmpty()) {
                    sentByName = ownerList[0].Name;
                }
            } catch (Exception ue) {
                System.debug('SignForce CERT PAGE: owner lookup failed (non-fatal): ' + ue.getMessage());
            }
        }

        if (agreement.Completed_Date__c != null) {
            completedDateStr = agreement.Completed_Date__c.format('MMM dd, yyyy, h:mm a z', orgTz());
        }
        if (agreement.Sent_Date__c != null) {
            sentDateStr = agreement.Sent_Date__c.format('MMM dd, yyyy, h:mm a z', orgTz());
        }

        List<Signer__c> rawSigners = new List<Signer__c>();
        try {
            rawSigners = GuestSigningApi.saSigners(agreementId);
        } catch (Exception se) {
            System.debug(LoggingLevel.WARN, 'SignForce CERT PAGE: signer query failed: ' + se.getMessage());
        }
        System.debug('SignForce CERT PAGE: found ' + rawSigners.size() + ' signers');

        // ── COMPLETION OVERLAY ─────────────────────────────────────────────
        // When the certificate is generated synchronously at completion time,
        // this render context CANNOT see the signing transaction's uncommitted
        // changes (the classic "old values" bug). The caller passes the
        // just-signed signer (fzSigner) and completion flag (fzDone) so we
        // overlay that final state in memory before building the page.
        Id fzSignerId = null;
        Boolean fzDone = false;
        DateTime fzTime = DateTime.now();
        String fzEmail = null;
        String fzIp = null;       // signer "Using IP Address" (IPv6) — render can't see uncommitted value
        String fzAuditIp = null;  // audit-trail "Document Signed" IP (IPv4)
        String fzCert = null;     // BUG-026: cert id is set in the same signing txn the render can't see
        try {
            String fzS = ApexPages.currentPage().getParameters().get('fzSigner');
            fzDone = ApexPages.currentPage().getParameters().get('fzDone') == '1';
            String fzA = ApexPages.currentPage().getParameters().get('fzAt');
            fzIp = ApexPages.currentPage().getParameters().get('fzIp');
            fzAuditIp = ApexPages.currentPage().getParameters().get('fzAuditIp');
            fzCert = ApexPages.currentPage().getParameters().get('fzCert');
            if (String.isNotBlank(fzA)) fzTime = DateTime.newInstance(Long.valueOf(fzA));
            if (String.isNotBlank(fzS)) fzSignerId = Id.valueOf(fzS);
        } catch (Exception pe) {
            fzSignerId = null; fzDone = false;
        }
        if (fzSignerId != null) {
            // Integrity guard: honor the overlay only if every OTHER signer has
            // already signed, i.e. this signer genuinely completes the flow.
            Boolean fzFound = false;
            Boolean othersSigned = true;
            for (Signer__c rs : rawSigners) {
                if (rs.Id == fzSignerId) { fzFound = true; continue; }
                // CC / Approver recipients never sign — they must NOT block the
                // completion overlay, else the certificate shows a stale
                // "Sent / Pending" even though the agreement is Completed. Only
                // other true Signers (Role = 'Signer', or null/legacy) gate it.
                if (rs.Role__c != null && rs.Role__c != 'Signer') continue;
                if (rs.Status__c != 'Signed' && rs.Signed_Date__c == null) othersSigned = false;
            }
            if (!fzFound || !othersSigned) { fzSignerId = null; fzDone = false; }
        } else {
            fzDone = false;
        }
        if (fzSignerId != null) {
            for (Signer__c rs : rawSigners) {
                if (rs.Id == fzSignerId) {
                    fzEmail = rs.Email__c;
                    // The render can't see the just-committed Signing_IP_Address__c,
                    // so overlay the IP passed in from the parent transaction.
                    if (String.isNotBlank(fzIp) && String.isBlank(rs.Signing_IP_Address__c)) {
                        rs.Signing_IP_Address__c = fzIp;
                    }
                    // BUG-026: same story for the certificate id — it's generated
                    // in the signing transaction, so overlay it or the FINAL
                    // signer's "Certificate ID" row renders blank.
                    if (String.isNotBlank(fzCert) && String.isBlank(rs.Signature_Certificate_ID__c)) {
                        rs.Signature_Certificate_ID__c = fzCert;
                    }
                    if (rs.Signed_Date__c == null) {
                        rs.Status__c = 'Signed';
                        rs.Signed_Date__c = fzTime;
                    }
                }
            }
        }
        if (fzDone) {
            agreement.Status__c = 'Completed';
            if (agreement.Completed_Date__c == null) agreement.Completed_Date__c = fzTime;
            completedDateStr = agreement.Completed_Date__c.format('MMM dd, yyyy, h:mm a z', orgTz());
        }
        // ───────────────────────────────────────────────────────────────────

        // Pre-fetch current signature fields for THIS agreement
        Map<Id, Signature_Field__c> signerToCurrentSig = new Map<Id, Signature_Field__c>();
        try {
            for (Signature_Field__c sf : GuestSigningApi.saSignatureFields(agreementId)) {
                if (sf.Assigned_Signer__c != null
                    && String.isNotBlank(sf.Field_Value__c)
                    && !signerToCurrentSig.containsKey(sf.Assigned_Signer__c)) {
                    signerToCurrentSig.put(sf.Assigned_Signer__c, sf);
                }
            }
        } catch (Exception fe) {
            System.debug('SignForce CERT PAGE: field fetch failed (non-fatal): ' + fe.getMessage());
        }

        for (Signer__c s : rawSigners) {
            SignerWrapper sw = new SignerWrapper();
            sw.signer = s;
            sw.hasSignature = false;
            sw.isDrawSignature = false;
            sw.isTypeSignature = false;
            sw.isUploadSignature = false;
            // Robust: a signer with a signed date is signed, even if a later
            // process touched the Status field.
            sw.isSigned = (s.Status__c == 'Signed') || (s.Signed_Date__c != null);
            sw.certificateId = s.Signature_Certificate_ID__c;
            sw.signingIpAddress = s.Signing_IP_Address__c;
            // Org default timezone (with zone label) so it lines up with the
            // audit trail, SENT, completed, and email timestamps.
            sw.signedDateStr = s.Signed_Date__c != null
                ? s.Signed_Date__c.format('MMM dd, yyyy, h:mm a z', orgTz())
                : 'Pending';

            Signature_Field__c currentSig = signerToCurrentSig.get(s.Id);
            if (currentSig != null && String.isNotBlank(currentSig.Field_Value__c)) {
                String val = currentSig.Field_Value__c;
                sw.hasSignature = true;
                sw.signatureData = val;

                if (val.startsWith('typed:')) {
                    sw.isTypeSignature = true;
                    sw.signatureType = 'Type';
                    List<String> parts = val.split(':');
                    sw.typedName = parts.size() > 1 ? parts[1] : s.Name;
                    sw.typedFont = parts.size() > 2 ? parts[2] : 'Dancing Script';
                    sw.fontFamily = sw.typedFont;
                } else if (val.startsWith('data:image')) {
                    sw.isUploadSignature = true;
                    sw.signatureType = 'Upload';
                } else if (val.startsWith('[')) {
                    sw.isDrawSignature = true;
                    sw.signatureType = 'Draw';
                } else {
                    sw.isDrawSignature = true;
                    sw.signatureType = 'Draw';
                }
            } else {
                // Fallback: Saved_Signature__c (legacy behavior, only if no current sig)
                try {
                    List<Saved_Signature__c> sigs = GuestSigningApi.savedSignatureFor(s.Email__c);
                    if (!sigs.isEmpty() && String.isNotBlank(sigs[0].Signature_Data__c)) {
                        sw.hasSignature = true;
                        sw.signatureData = sigs[0].Signature_Data__c;
                        sw.signatureType = sigs[0].Signature_Type__c;
                        sw.fontFamily = sigs[0].Font_Family__c;

                        if (sigs[0].Signature_Type__c == 'Draw') {
                            sw.isDrawSignature = true;
                        } else if (sigs[0].Signature_Type__c == 'Type') {
                            sw.isTypeSignature = true;
                            List<String> parts = sigs[0].Signature_Data__c.split(':');
                            sw.typedName = parts.size() > 1 ? parts[1] : s.Name;
                            sw.typedFont = parts.size() > 2 ? parts[2] : 'Dancing Script';
                        } else if (sigs[0].Signature_Type__c == 'Upload') {
                            sw.isUploadSignature = true;
                        }
                    }
                } catch (Exception svr) {
                    System.debug('SignForce CERT PAGE: saved-sig lookup failed (non-fatal): ' + svr.getMessage());
                }
            }
            signers.add(sw);
        }

        try {
            auditEvents = GuestSigningApi.auditRowsFor(agreementId);
        } catch (Exception ae) {
            System.debug('SignForce CERT PAGE: audit event query failed (non-fatal): ' + ae.getMessage());
            auditEvents = new List<Signing_Event__c>();
        }

        // Completion overlay (part 2): append the just-committed audit events
        // this render cannot yet see, so the certificate's trail is complete.
        if (fzSignerId != null) {
            Boolean hasSignedEvt = false;
            Boolean hasCompletedEvt = false;
            for (Signing_Event__c ev : auditEvents) {
                if (ev.Event_Timestamp__c == null) continue;
                Long diff = Math.abs(ev.Event_Timestamp__c.getTime() - fzTime.getTime());
                if (diff < 120000 && ev.Action__c == 'Document Signed'
                    && ev.Signer_Email__c == fzEmail) hasSignedEvt = true;
                if (diff < 120000 && ev.Action__c == 'Agreement Completed') hasCompletedEvt = true;
            }
            if (!hasSignedEvt) {
                auditEvents.add(new Signing_Event__c(
                    Action__c = 'Document Signed',
                    Signer_Email__c = fzEmail,
                    IP_Address__c = (String.isNotBlank(fzAuditIp) ? fzAuditIp : fzIp),
                    Event_Timestamp__c = fzTime));
            }
            if (fzDone && !hasCompletedEvt) {
                auditEvents.add(new Signing_Event__c(
                    Action__c = 'Agreement Completed',
                    Event_Timestamp__c = fzTime));
            }
        }

        // Build the display rows with timestamps formatted in the org default
        // timezone (with zone label), so the audit trail matches the SENT,
        // SIGNED, completed and generated timestamps instead of raw UTC.
        for (Signing_Event__c ev : auditEvents) {
            AuditRow ar = new AuditRow();
            ar.action = ev.Action__c;
            ar.signerEmail = ev.Signer_Email__c;
            ar.ipAddress = ev.IP_Address__c;
            ar.timestampStr = ev.Event_Timestamp__c != null
                ? ev.Event_Timestamp__c.format('MMM dd, yyyy, h:mm a z', orgTz())
                : '';
            auditRows.add(ar);
        }

        hasData = true;
        System.debug('SignForce CERT PAGE: hasData=true, signers=' + signers.size() + ', audit=' + auditEvents.size());
    }

    // Deliberately NOT @AuraEnabled: every real caller is server-side Apex
    // (GuestSigningApi, CompletionEmailQueueable). Exposing it to the
    // client would let a guest regenerate the certificate of an arbitrary
    // agreement by Id, with no token proving they belong to it.
    public static void generateAndAttachPDF(Id agreementId) {
        generateAndAttachPDF(agreementId, null, false);
    }

    /**
     * Completion-time overload: passes the just-signed signer and completion
     * flag to the render as URL params, so the certificate shows the FINAL
     * state even though the render context cannot see this transaction's
     * uncommitted changes.
     */
    public static void generateAndAttachPDF(Id agreementId, Id justSignedId, Boolean justCompleted) {
        try {
            System.debug('PDF GEN: Start for agreementId = ' + agreementId);

            Agreement__c agr = GuestSigningApi.saAgreementName(agreementId);
            String fileTitle = agr.Name + ' - Signing Certificate';

            // ── ORDER MATTERS ──
            // 1) Render the PDF FIRST (getContentAsPDF is a callout in async
            //    contexts — any DML before it would throw "uncommitted work").
            // 2) Validate the blob (a blank render is ~<2KB; never replace an
            //    existing good certificate with a blank one).
            // 3) Only THEN delete the old cert and insert the fresh one.
            PageReference pdfPage = Page.SignedAgreementPDF;
            // CRITICAL FIX: pass as String not Id
            pdfPage.getParameters().put('agreementId', String.valueOf(agreementId));
            if (justSignedId != null) {
                pdfPage.getParameters().put('fzSigner', String.valueOf(justSignedId));
                pdfPage.getParameters().put('fzAt', String.valueOf(DateTime.now().getTime()));
                if (justCompleted == true) pdfPage.getParameters().put('fzDone', '1');
                // The PDF render context can't see this transaction's uncommitted
                // changes, but THIS (parent) context can — read them and pass through:
                //   fzIp      = signer "Using IP Address" (IPv6) on the Signer record
                //   fzAuditIp = "Document Signed" audit-trail IP (IPv4) on the event
                try {
                    Signer__c sgnIp = GuestSigningApi.saSignerIp(justSignedId);
                    if (String.isNotBlank(sgnIp.Signing_IP_Address__c)) {
                        pdfPage.getParameters().put('fzIp', sgnIp.Signing_IP_Address__c);
                    }
                    // BUG-026: pass the just-committed certificate id through so the
                    // render can overlay it for the final signer.
                    if (String.isNotBlank(sgnIp.Signature_Certificate_ID__c)) {
                        pdfPage.getParameters().put('fzCert', sgnIp.Signature_Certificate_ID__c);
                    }
                } catch (Exception ipe) { /* non-fatal */ }
                try {
                    List<Signing_Event__c> dsEv = GuestSigningApi.saDocumentSignedEvent(agreementId);
                    if (!dsEv.isEmpty() && String.isNotBlank(dsEv[0].IP_Address__c)) {
                        pdfPage.getParameters().put('fzAuditIp', dsEv[0].IP_Address__c);
                    }
                } catch (Exception ae) { /* non-fatal */ }
            }

            Blob pdfBlob;
            if (Test.isRunningTest()) {
                pdfBlob = Blob.valueOf('Test certificate PDF placeholder');
            } else {
                pdfBlob = pdfPage.getContentAsPDF();
            }

            Integer sz = pdfBlob != null ? pdfBlob.size() : 0;
            System.debug('PDF GEN: blob size = ' + sz);
            if (sz < 2000 && !Test.isRunningTest()) {
                // Blank/failed render — keep whatever certificate already exists.
                System.debug(LoggingLevel.WARN, 'PDF GEN: tiny blob (' + sz + ' bytes), keeping existing certificate.');
                return;
            }

            GuestSigningApi.saAttachCertificate(agreementId, fileTitle, pdfBlob);

            System.debug('PDF GEN: File inserted & linked, size=' + sz);

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'PDF GEN ERROR: ' + e.getMessage()
                + ' :: ' + e.getStackTraceString());
            throw new AuraHandledException(e.getMessage());
        }
    }
}