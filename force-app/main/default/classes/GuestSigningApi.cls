/**
 * GuestSigningApi — one consolidated, self-contained guest-facing API surface.
 *
 * Standalone class (NOT added to the managed package). It carries its OWN copy of
 * every guest signing entry point — the full method bodies, private helpers and
 * fields are inlined here, not delegated to AgreementControllerGuest — so this
 * class can serve the guest portal on its own without touching existing code.
 *
 * Mirrors AgreementControllerGuest (signingViewer, signatureCanvas LWCs).
 */
public without sharing class GuestSigningApi {

    // ═════════════════════════════════════════════════════════════════════
    //  TOKEN-LOOKUP / LIFECYCLE METHODS
    // ═════════════════════════════════════════════════════════════════════

    @AuraEnabled
    public static Map<String, Object> getSignerByTokenSecure(String token) {
        return AgreementServiceGuest.validateToken(token);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  SIGNING SESSION (strict single-tab binding — see SignForceSessionService)
    // ─────────────────────────────────────────────────────────────────────

    /**
     * Called once when a tab first opens the signing link. Binds the session to
     * this tab and returns a session token for the browser to keep in
     * sessionStorage. Returns null if the link is already bound to another
     * tab/device — the LWC then shows "session timed out".
     */
    @AuraEnabled
    public static String startSigningSession(String token) {
        Signer__c signer = requireSignerForToken(token);

        // Strict: the first browser to consent owns the link. Every later
        // browser, incognito window and device is turned away — that is the
        // whole point of the binding. (Call this ONLY from a genuine signer
        // gesture — the consent gate's Continue click — not on page load, or
        // email security scanners consume the binding first.)
        if (String.isNotBlank(signer.Session_Token_Hash__c)) {
            auditLog(signer.Agreement__c, 'Signing Session Blocked', signer.Email__c, null, null);
            return null;
        }

        String sessionToken = EncodingUtil.convertToHex(Crypto.generateAesKey(128));

        Signer__c upd = new Signer__c(Id = signer.Id);
        upd.Session_Token_Hash__c = sha256Hex(sessionToken);
        upd.Session_Bound_At__c   = DateTime.now();
        update upd;
        invalidateToken(token);

        auditLog(signer.Agreement__c, 'Signing Session Started', signer.Email__c, null, null);
        return sessionToken;
    }

    /**
     * Called on reload to confirm the stored session token is still the bound
     * one (so a genuine refresh isn't re-gated). Returns true/false, never throws.
     */
    @AuraEnabled
    public static Boolean validateSigningSession(String token, String sessionToken) {
        if (String.isBlank(sessionToken)) return false;
        try {
            requireVerifiedSignerForToken(token, sessionToken);
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    @AuraEnabled
    public static void declineAgreementSecure(String token, String sessionToken, String reason) {
        Signer__c signer = requireVerifiedSignerForToken(token, sessionToken);
        AgreementServiceGuest.declineAgreementGuest(signer.Id, reason);
    }

    /**
     * Records that a signer accepted the Electronic Record & Signature Disclosure,
     * as its own audit-trail row (Action = 'Consent Accepted') with the moment, IP
     * and user agent. This is the discrete consent-accepted event the certificate
     * was missing — previously consent was only implied by the later 'Document
     * Signed' event.
     *
     * Resolved by token (not the signing session) because the consent gate is shown
     * before the session may be established. Idempotent — clicking Continue again
     * does not add a second row. Best-effort: an audit-write failure must never stop
     * the signer from proceeding, so the LWC calls this fire-and-forget.
     */
    @AuraEnabled
    public static void logConsentAccepted(String token, String ipAddress, String userAgent) {
        if (String.isBlank(token)) return;
        try {
            List<Signer__c> signers = [
                SELECT Id, Email__c, Agreement__c
                FROM Signer__c WHERE Access_Token__c = :token LIMIT 1
            ];
            if (signers.isEmpty()) return;
            Signer__c s = signers[0];

            Integer already = [
                SELECT COUNT() FROM Signing_Event__c
                WHERE Agreement__c = :s.Agreement__c
                AND Action__c = 'Consent Accepted'
                AND Signer_Email__c = :s.Email__c
            ];
            if (already > 0) return;

            auditLog(s.Agreement__c, 'Consent Accepted', s.Email__c, ipAddress, userAgent);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'logConsentAccepted skipped: ' + e.getMessage());
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    //  OTP IDENTITY GATE (emailed one-time code before the document loads)
    // ─────────────────────────────────────────────────────────────────────

    /**
     * Render the signing certificate SYNCHRONOUSLY in its own transaction,
     * called by the viewer right after completeSigningSecure succeeds.
     *
     * Why a separate call and not inline in completeSigningSecure: getContentAsPDF
     * is CPU/heap heavy and a governor breach mid-render throws an uncatchable
     * System.LimitException that would roll back the whole signature (a bare 500).
     * Why not async: getContentAsPDF in a queueable/@future loses the request
     * context and renders a blank (~789-byte) certificate. This method gets both
     * — a fresh transaction with full limits AND a live guest session, so the
     * certificate renders WITH content — and a failure here cannot undo the
     * already-committed signature. Best-effort: never throws to the caller.
     */
    @AuraEnabled
    public static Map<String, Object> generateSigningCertificateSecure(String token, String sessionToken) {
        try {
            // Cert-render authz ALLOWS an already-signed signer — this call runs
            // right after markSigned flipped the signer to 'Signed', and the
            // normal requireVerifiedSignerForToken would deny it ("already
            // signed"), which is exactly why the certificate never attached.
            Signer__c signer = requireVerifiedSignerForCertRender(token, sessionToken);
            SignedAgreementPDFController.generateAndAttachPDF(signer.Agreement__c, signer.Id, true);
            return new Map<String, Object>{ 'success' => true };
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'generateSigningCertificateSecure failed (non-fatal, async will retry): ' + e.getMessage());
            return new Map<String, Object>{ 'success' => false, 'message' => e.getMessage() };
        }
    }

    /**
     * Emails the signer a one-time verification code, or refuses with the
     * remaining cooldown when one was sent under 60 seconds ago. Resolved by
     * token like the sibling methods; OTPService owns the OTP semantics
     * (cooldown, expiry, attempt cap) — this method only authorises and audits.
     */
    @AuraEnabled
    public static Map<String, Object> sendSigningOtp(String token) {
        // Each step isolated so any failure names WHICH step and surfaces the
        // real class.method:line to the LWC console — otherwise a subscriber-org
        // error (managed Apex logs are empty there) is impossible to locate.
        Signer__c signer;
        try {
            signer = requireSignerForToken(token);
        } catch (Exception e) {
            throw otpDiag('authz', e);
        }

        Map<String, Object> result;
        try {
            result = OTPService.sendSigningOtp(signer.Id);
        } catch (Exception e) {
            throw otpDiag('otp-send', e);
        }

        // Audit is best-effort: a failure here must NOT fail an OTP that already
        // sent (the email is out; the log is secondary).
        if (result.get('success') == true) {
            try {
                auditLog(signer.Agreement__c, 'OTP Sent', signer.Email__c, null, null);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'OTP audit non-fatal: ' + e.getMessage());
            }
        }
        return result;
    }

    /**
     * Wraps a step failure so the browser console shows the step, the exception
     * type + message, AND the first stack frame (class.method: line) — the only
     * way to locate a fault in managed Apex, whose logs are empty in a
     * subscriber org. AuraHandledException keeps its own message only after
     * setMessage(), so we call it.
     */
    private static AuraHandledException otpDiag(String step, Exception e) {
        String frame = '';
        String st = e.getStackTraceString();
        if (String.isNotBlank(st)) {
            frame = ' @ ' + st.split('\n')[0];
        }
        String msg = '[' + step + '] ' + e.getTypeName() + ': ' + e.getMessage() + frame;
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }

    /**
     * Verifies the entered code. Wrong codes burn one of five attempts; the
     * fifth failure locks (invalidates) the code so a fresh send is required.
     */
    @AuraEnabled
    public static Map<String, Object> verifySigningOtp(String token, String code) {
        Signer__c signer = requireSignerForToken(token);
        Map<String, Object> result = OTPService.verifySigningOtp(signer.Id, code);
        // 'alreadyVerified' marks the idempotent re-check path (page refresh
        // after verifying) — that one must not add a second audit row.
        if (result.get('verified') == true && result.get('alreadyVerified') != true) {
            auditLog(signer.Agreement__c, 'OTP Verified', signer.Email__c, null, null);
        }
        return result;
    }

    @AuraEnabled
    public static Map<String, Object> completeSigningSecure(
        String token, String sessionToken, String ipAddress, String userAgent, String ipAddressV4
    ) {
        // Each sync step named so a subscriber-org 500 (managed logs are empty
        // there) surfaces WHICH step + class.method:line to the LWC console.
        Signer__c signer;
        try {
            signer = requireVerifiedSignerForToken(token, sessionToken);
        } catch (Exception e) {
            throw otpDiag('complete-authz', e);
        }
        Id signerId = signer.Id;
        Id agreementId = signer.Agreement__c;

        // 1. Mark signed (sync, must succeed). ipAddress (IPv6) → signer record
        //    ("Using IP Address"); ipAddressV4 → Audit Trail "Document Signed".
        System.debug(LoggingLevel.INFO,
            '[SignForce IP] completeSigningSecure ipAddress(v6)=[' + ipAddress
            + '] ipAddressV4=[' + ipAddressV4 + ']');

        // Claim the stamp for this path BEFORE markSigned commits the Completed
        // status, because that DML is what fires AgreementTrigger. If the trigger
        // queued a stamp too, both jobs would call the backend concurrently and
        // each would write its own file into the customer's Drive. Stamping for
        // this signing session is queued below, once.
        AgreementControllerGuest.suppressCompletionStampTrigger = true;
        try {
            AgreementServiceGuest.markSigned(signerId, ipAddress, ipAddressV4, userAgent);
        } catch (Exception e) {
            throw otpDiag('mark-signed', e);
        }

        // Re-read to check completion
        Signer__c after;
        try {
            after = [
                SELECT Agreement__c, Signature_Certificate_ID__c, Agreement__r.Status__c
                FROM Signer__c WHERE Id = :signerId LIMIT 1
            ];
        } catch (Exception e) {
            throw otpDiag('complete-reread', e);
        }
        Boolean isCompleted = (after.Agreement__r.Status__c == 'Completed');

        // The "you have signed successfully" confirmation is sent inside
        // AgreementService.markSigned above, so every signing entry point behaves
        // the same way.

        if (isCompleted) {
            // Certificate + Stamped + Email ALL run ASYNC. The certificate is NOT
            // rendered inline here on purpose: getContentAsPDF() is CPU/heap heavy
            // and a governor breach mid-render throws System.LimitException, which
            // `catch (Exception)` CANNOT catch — it rolled back the whole signature
            // and handed the signer a bare 500. CompletionEmailQueueable's CERT
            // phase regenerates the certificate in its OWN fresh transaction (with
            // committed data) and validates the blob before swapping, so the signer
            // still gets a certificate — without ever risking the completion. The
            // sync transaction now does only markSigned + the async enqueue, so it
            // has no room to breach a limit.
            //
            // Stamped uses a Lambda HTTP callout so it must be async anyway (no
            // callouts after the markSigned DML). Email is sent after Stamped.
            try {
                runStampingAndEmailAsync(agreementId);
                System.debug('SignForce: Queued async certificate + stamping + email for ' + agreementId);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR,
                    'SignForce: Failed to queue async flow: ' + e.getMessage());
            }
        }

        if (!isCompleted) {
            // SEQUENTIAL/PARALLEL MID-FLOW: this signer is done but others are
            // still pending. Re-stamp the document so the next signer sees the
            // signatures collected so far. (Their invite was already sent inside
            // markSigned -> checkAgreementCompletion, and this signer's own
            // confirmation went out above.)
            try {
                runMidSignStampAndCopyAsync(agreementId, signerId);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    '[Guest] mid-sign stamp/copy enqueue failed (non-fatal): ' + e.getMessage());
            }
        }

        return new Map<String, Object>{
            'isCompleted'   => isCompleted,
            'agreementId'   => agreementId,
            'certificateId' => after.Signature_Certificate_ID__c
        };
    }

    /**
     * Mid-flow async: re-stamp the document with the signatures collected so
     * far (partial), then email the just-signed signer their copy. Runs in its
     * own transaction so Lambda callouts never hit "uncommitted work pending".
     */
    @future(callout=true)
    public static void runMidSignStampAndCopyAsync(Id agreementId, Id signerId) {
        // This stamp is PARTIAL — it carries the signatures collected so far, not
        // all of them. Only the final stamp belongs in the customer's Drive /
        // OneDrive, so the cloud-tier stamping path (which publishes straight into
        // their Stamped folder) is suppressed for the duration of this one.
        AgreementControllerGuest.suppressCloudStampUpload = true;
        try {
            AgreementControllerGuest.generateStampedPDFServerGuest(agreementId);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, '[MidSign] stamping failed: ' + e.getMessage());
        }
        // RACE GUARD: if the LAST signer finished while this partial stamp was
        // running, our partial stamp may have replaced the FINAL one. Re-check
        // and re-stamp so the final document always carries every signature.
        //
        // The re-stamp below is a FINAL stamp, so the suppression is lifted first
        // — otherwise the one case where this job produces the complete document
        // would be the one case that never reaches the customer's folder.
        AgreementControllerGuest.suppressCloudStampUpload = false;
        try {
            Agreement__c chk = [
                SELECT Status__c, Completed_Date__c
                FROM Agreement__c WHERE Id = :agreementId
            ];
            if (chk.Status__c == 'Completed') {
                // Only re-stamp if no FINAL stamp exists yet.
                //
                // completeSigningSecure enqueues runStampingAndEmailAsync the moment
                // the envelope completes, and that job stamps too. Without this
                // check both jobs stamp, and on a Cloud-tier agreement each stamp
                // publishes its own file — so the fix for "a file per signer" would
                // have been replaced by "two files at the end".
                //
                // generateStampedPDFServerGuest carries the same guard internally, but
                // relying on it alone leaves both jobs able to read "no final stamp"
                // before either writes one. Checking here shrinks that window to the
                // gap between this query and the callout. Closing it completely
                // needs a lock the platform does not give async jobs; the remaining
                // exposure is far smaller than the bug being fixed.
                Boolean finalStampExists = chk.Completed_Date__c != null && 0 < [
                    SELECT COUNT() FROM Agreement_Document__c
                    WHERE Agreement__c = :agreementId
                    AND Document_Type__c = 'Stamped'
                    AND CreatedDate >= :chk.Completed_Date__c
                ];
                if (!finalStampExists) {
                    AgreementControllerGuest.generateStampedPDFServerGuest(agreementId);
                } else {
                    System.debug('[MidSign] final stamp already present, skipping race re-stamp');
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, '[MidSign] race re-stamp check failed: ' + e.getMessage());
        }
        // No email here: the "you have signed successfully" confirmation is sent
        // synchronously by completeSigningSecure for every signer. This job only
        // keeps the stamped document current so the next signer sees the
        // signatures collected so far.
    }

    /** True only if a Stamped doc exists that is NOT in the given pre-existing set. */
    private static Boolean hasNewStampedDocument(Id agreementId, Set<Id> excludeIds) {
        return [
            SELECT COUNT() FROM Agreement_Document__c
            WHERE Agreement__c = :agreementId
            AND Document_Type__c = 'Stamped'
            AND Id NOT IN :excludeIds
        ] > 0;
    }

    /**
     * Async wrapper: Stamping (Lambda callouts) + Email send.
     * - Stamping must be async because callouts after markSigned()'s DML
     *   throw "Uncommitted work pending" in sync context.
     * - Email is sent in same async transaction so it runs AFTER Stamped
     *   record is persisted.
     * - Certificate is NOT generated here — it's done synchronously in
     *   completeSigningSecure() because async/guest context produces blank PDF.
     */
    @future(callout=true)
    public static void runStampingAndEmailAsync(Id agreementId) {
        // ── Step 1: Stamping (auto-retry for transient Lambda failures) ──
        // Up to MAX_ATTEMPTS tries in this async transaction. generateStamped...
        // inserts the Stamped record only AFTER a successful Lambda callout, so a
        // failed attempt leaves no partial record (safe to retry).
        //
        // IMPORTANT: a Stamped doc may already exist from the MID-FLOW partial
        // stamp (signers 1..N-1). Completion must ALWAYS re-stamp so the FINAL
        // signer's signature is included — generateStampedPDFServerGuest deletes the
        // old Stamped doc and inserts a fresh one, so this is safe. The
        // existence check is therefore only used between retry attempts, and
        // only counts a stamped doc CREATED BY THIS RUN (not the pre-existing
        // partial one).
        Boolean stampOk = false;
        String lastErr = null;
        final Integer MAX_ATTEMPTS = 2;

        Set<Id> preExistingStamped = new Map<Id, Agreement_Document__c>([
            SELECT Id FROM Agreement_Document__c
            WHERE Agreement__c = :agreementId AND Document_Type__c = 'Stamped'
        ]).keySet();

        for (Integer attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
            if (attempt > 1 && hasNewStampedDocument(agreementId, preExistingStamped)) { stampOk = true; break; }
            try {
                System.debug('SignForce ASYNC: ===== Stamping attempt ' + attempt + ' =====');
                AgreementControllerGuest.generateStampedPDFServerGuest(agreementId);
                stampOk = true;
                break;
            } catch (Exception e) {
                lastErr = e.getMessage();
                System.debug(LoggingLevel.ERROR,
                    'SignForce ASYNC STAMPING attempt ' + attempt + ' FAILED: ' + e.getMessage()
                    + '\n  Stack: ' + e.getStackTraceString());
            }
        }

        // Confirm a fresh Stamped record actually exists (covers a silent no-op).
        if (!stampOk) stampOk = hasNewStampedDocument(agreementId, preExistingStamped);

        // ── Visible status via the Audit Trail (no schema change needed) ──
        // Success → "Stamped Document Generated"; failure → "Stamped Document
        // Failed" with the last error, so the gap is visible on the agreement
        // instead of being buried in debug logs only.
        try {
            if (stampOk) {
                auditLog(agreementId, 'Stamped Document Generated', 'guest@signforce.com', null, null);
            } else {
                // Reason goes in Notes__c (6-arg overload), not User_Agent__c.
                // Passing it as the 5th argument put it in the user-agent field,
                // which the record page does not show — so every stamping failure
                // looked like it had no explanation at all.
                auditLog(agreementId, 'Stamped Document Failed', 'guest@signforce.com', null, null,
                    'Stamping failed after ' + MAX_ATTEMPTS + ' attempt(s)'
                    + (String.isNotBlank(lastErr) ? (': ' + lastErr) : ''));
            }
        } catch (Exception logEx) {
            System.debug(LoggingLevel.WARN, 'SignForce ASYNC: audit log failed: ' + logEx.getMessage());
        }

        // ── Step 2: Email — both Stamped (just-made) and Certificate (made sync
        // before we got here) are persisted in Agreement_Document__c. Email is
        // still sent even if stamping failed so signers receive the signing
        // certificate; the audit entry above flags the missing stamped PDF.
        try {
            // Email must run in its OWN transaction: the stamping/audit DML above
            // is uncommitted here, and Salesforce blocks HTTP callouts after
            // uncommitted DML — so the email's S3 fetches (stamped/original PDFs)
            // would fail and only the CV-based certificate would attach. The
            // queueable starts fresh AFTER this transaction commits.
            System.debug('SignForce ASYNC: ===== Queueing email send (own transaction) =====');
            System.enqueueJob(new CompletionEmailQueueable(agreementId));
        } catch (Exception e) {
            // Enqueue failed (e.g. queueable limit) — last resort: send inline.
            // CV-based attachments still work; S3 ones may be skipped.
            System.debug(LoggingLevel.ERROR, 'SignForce ASYNC: enqueue failed, sending inline: ' + e.getMessage());
            try {
                AgreementServiceGuest.sendCompletionEmailsPublic(agreementId);
            } catch (Exception e2) {
                System.debug(LoggingLevel.ERROR,
                    'SignForce ASYNC EMAIL FAILED: ' + e2.getMessage()
                    + '\n  Stack: ' + e2.getStackTraceString());
            }
        }
    }

    /** True if a Stamped document already exists for the agreement. */
    private static Boolean hasStampedDocument(Id agreementId) {
        List<Agreement_Document__c> existing = [
            SELECT Id FROM Agreement_Document__c
            WHERE Agreement__c = :agreementId AND Document_Type__c = 'Stamped'
            LIMIT 1
        ];
        return !existing.isEmpty();
    }

    /**
     * Async wrapper for stamping + cert + email.
     * Runs in a fresh transaction so HTTP callouts work cleanly without
     * "Uncommitted work pending" from markSigned's DML.
     */
    @future(callout=true)
    public static void runPostSigningFlowAsync(Id agreementId) {
        // Step 1: Stamping (Lambda callouts + DML for Stamped record)
        try {
            System.debug('SignForce ASYNC: ===== Starting stamping =====');
            AgreementControllerGuest.generateStampedPDFServerGuest(agreementId);
            System.debug('SignForce ASYNC: ===== Stamping completed =====');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'SignForce ASYNC STAMPING FAILED: ' + e.getMessage()
                + '\n  Stack: ' + e.getStackTraceString());
        }

        // Diagnostic: verify Stamped record created
        List<Agreement_Document__c> stampedCheck = [
            SELECT Id, S3_Document_ID__c
            FROM Agreement_Document__c
            WHERE Agreement__c = :agreementId AND Document_Type__c = 'Stamped'
            ORDER BY CreatedDate DESC LIMIT 1
        ];
        if (stampedCheck.isEmpty()) {
            System.debug(LoggingLevel.ERROR,
                'SignForce ASYNC: NO STAMPED RECORD CREATED for ' + agreementId);
        } else {
            System.debug('SignForce ASYNC: Stamped record OK, S3='
                + stampedCheck[0].S3_Document_ID__c);
        }

        // Step 2: Certificate
        try {
            System.debug('SignForce ASYNC: ===== Starting certificate =====');
            SignedAgreementPDFController.generateAndAttachPDF(agreementId);
            System.debug('SignForce ASYNC: ===== Certificate completed =====');
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'SignForce ASYNC Certificate failed: ' + e.getMessage());
        }

        // Step 2.5: Push to integrations (Google Drive, etc.)
        try {
            System.debug('SignForce ASYNC: ===== Starting cloud push =====');
            IntegrationServiceGuest.pushAgreementDocuments(agreementId);
            System.debug('SignForce ASYNC: ===== Cloud push completed =====');
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'SignForce ASYNC Cloud push failed: ' + e.getMessage());
        }

        // Step 3: Email
        try {
            System.debug('SignForce ASYNC: ===== Starting email send =====');
            AgreementServiceGuest.sendCompletionEmailsPublic(agreementId);
            System.debug('SignForce ASYNC: ===== Email send completed =====');
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'SignForce ASYNC EMAIL FAILED: ' + e.getMessage() + '\n  Stack: ' + e.getStackTraceString());
        }
    }

    // ═════════════════════════════════════════════════════════════════════
    //  FIELD METHODS
    // ═════════════════════════════════════════════════════════════════════

    @AuraEnabled
    public static List<Signature_Field__c> getFieldsForSignerSecure(String token) {
        Signer__c signer = requireSignerForToken(token);
        return [
            SELECT Id, Field_Type__c, Field_Label__c, Page_Number__c,
                   X_Position__c, Y_Position__c, Width__c, Height__c,
                   Is_Required__c, Is_Completed__c, Field_Value__c, Page_Width__c
            FROM Signature_Field__c
            WHERE Agreement__c = :signer.Agreement__c
              AND Assigned_Signer__c = :signer.Id
            ORDER BY Page_Number__c ASC, Y_Position__c ASC
        ];
    }

    /**
     * Read-only layer for the signing viewer: completed fields belonging to
     * OTHER signers, so signer #2 sees signer #1's signature on the document
     * (and #3 sees #1 + #2), exactly like DocuSign.
     */
    @AuraEnabled
    public static List<Signature_Field__c> getOtherCompletedFieldsSecure(String token) {
        Signer__c signer = requireSignerForToken(token);
        return [
            SELECT Id, Field_Type__c, Field_Label__c, Page_Number__c,
                   X_Position__c, Y_Position__c, Width__c, Height__c,
                   Is_Required__c, Is_Completed__c, Field_Value__c, Page_Width__c
            FROM Signature_Field__c
            WHERE Agreement__c = :signer.Agreement__c
              AND Assigned_Signer__c != :signer.Id
              AND Is_Completed__c = true
            ORDER BY Page_Number__c ASC, Y_Position__c ASC
        ];
    }

    @AuraEnabled
    public static void saveFieldValuesSecure(String token, String fieldValuesJson) {
        if (String.isBlank(fieldValuesJson)) return;

        List<Object> raw = (List<Object>) JSON.deserializeUntyped(fieldValuesJson);
        Set<Id> claimedIds = new Set<Id>();
        Map<Id, String> idToValue = new Map<Id, String>();
        for (Object obj : raw) {
            Map<String, Object> fv = (Map<String, Object>) obj;
            String fieldIdStr = (String) fv.get('id');
            if (String.isBlank(fieldIdStr)) continue;
            Id fid;
            try { fid = (Id) fieldIdStr; } catch (Exception e) { continue; }
            claimedIds.add(fid);
            idToValue.put(fid, (String) fv.get('value'));
        }
        if (claimedIds.isEmpty()) return;

        Set<Id> ok = requireFieldsBelongToSigner(token, claimedIds);

        List<Signature_Field__c> toUpdate = new List<Signature_Field__c>();
        for (Id fid : ok) {
            String v = idToValue.get(fid);
            Signature_Field__c f = new Signature_Field__c(Id = fid);
            f.Field_Value__c = v;
            f.Is_Completed__c = String.isNotBlank(v);
            toUpdate.add(f);
        }
        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }
    }

    // ═════════════════════════════════════════════════════════════════════
    //  DOCUMENT METHODS
    // ═════════════════════════════════════════════════════════════════════

    @AuraEnabled
    public static String getDocumentVersionSecure(String token) {
        Signer__c signer = requireSignerForToken(token);

        List<Agreement_Document__c> docs = [
            SELECT Content_Version_ID__c
            FROM Agreement_Document__c
            WHERE Agreement__c = :signer.Agreement__c
              AND Document_Type__c = 'Original'
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (!docs.isEmpty() && String.isNotBlank(docs[0].Content_Version_ID__c)) {
            return docs[0].Content_Version_ID__c;
        }

        List<ContentDocumentLink> links = [
            SELECT ContentDocument.LatestPublishedVersionId,
                   ContentDocument.Title
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :signer.Agreement__c
              AND ContentDocument.FileType IN ('PDF','DOCX','DOC','WORD')
            ORDER BY ContentDocument.CreatedDate ASC
        ];
        for (ContentDocumentLink l : links) {
            String title = l.ContentDocument.Title;
            if (!title.endsWith('- Signed Document') && !title.endsWith('Signed')) {
                return l.ContentDocument.LatestPublishedVersionId;
            }
        }
        return null;
    }

    /**
     * Returns a PDFPreview URL for the agreement's Original document, suitable
     * for use as iframe.src in the guest signing portal. (See
     * AgreementControllerGuest for the full rationale — mirrors
     * DocumentEditorController.getPublicPreviewUrl but token-authorized.)
     */
    @AuraEnabled
    public static String getPublicPreviewUrlSecure(String token, String sessionToken) {
        Signer__c signer = requireVerifiedSignerForToken(token, sessionToken);

        // Resolve the CV the same way getDocumentVersionSecure does — prefer
        // the explicit Agreement_Document__c 'Original' row, fall back to the
        // oldest non-Signed ContentDocumentLink.
        String cvId = null;

        List<Agreement_Document__c> docs = [
            SELECT Content_Version_ID__c
            FROM Agreement_Document__c
            WHERE Agreement__c = :signer.Agreement__c
              AND Document_Type__c = 'Original'
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (!docs.isEmpty() && String.isNotBlank(docs[0].Content_Version_ID__c)) {
            cvId = docs[0].Content_Version_ID__c;
        } else {
            List<ContentDocumentLink> links = [
                SELECT ContentDocument.LatestPublishedVersionId,
                       ContentDocument.Title
                FROM ContentDocumentLink
                WHERE LinkedEntityId = :signer.Agreement__c
                  AND ContentDocument.FileType IN ('PDF','DOCX','DOC','WORD')
                ORDER BY ContentDocument.CreatedDate ASC
            ];
            for (ContentDocumentLink l : links) {
                String title = l.ContentDocument.Title;
                if (!title.endsWith('- Signed Document') && !title.endsWith('Signed')) {
                    cvId = l.ContentDocument.LatestPublishedVersionId;
                    break;
                }
            }
        }

        if (String.isBlank(cvId)) return null;

        List<ContentVersion> cvs = [
            SELECT Id, FileExtension, VersionData, PathOnClient, Title, ContentSize
            FROM ContentVersion WHERE Id = :cvId LIMIT 1
        ];
        if (cvs.isEmpty()) return null;
        ContentVersion cv = cvs[0];
        String ext = cv.FileExtension != null ? cv.FileExtension.toLowerCase() : '';

        // Guests cannot use /apex/PDFPreview?cvId=... (no Salesforce session), so
        // always route through Lambda convertToPdf → presigned S3 URL, which needs
        // no Salesforce auth.
        if (ext == 'pdf' || ext == 'docx' || ext == 'doc') {
            try {
                String s3Url = DocumentEditorControllerGuest.convertToPdfViaLambda(cv);
                if (String.isNotBlank(s3Url)) {
                    return pdfPreviewBase() + '?pdfUrl='
                        + EncodingUtil.urlEncode(s3Url, 'UTF-8')
                        + '&ts=' + System.currentTimeMillis();
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR,
                    '[GuestSigningApi] Lambda conversion failed for guest preview: '
                    + e.getMessage());
                throw new AuraHandledException(
                    'Could not prepare document for preview. Please contact support.'
                );
            }
        }

        return pdfPreviewBase() + '?cvId=' + cvId
            + '&ts=' + System.currentTimeMillis();
    }

    @AuraEnabled
    public static Map<String, Object> getDocumentForSigningSecure(String token) {
        Signer__c signer = requireSignerForToken(token);
        Map<String, Object> result = new Map<String, Object>();

        List<Agreement_Document__c> docs = [
            SELECT Content_Version_ID__c
            FROM Agreement_Document__c
            WHERE Agreement__c = :signer.Agreement__c
              AND Document_Type__c = 'Original'
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (docs.isEmpty() || String.isBlank(docs[0].Content_Version_ID__c)) {
            return result;
        }

        String cvId = docs[0].Content_Version_ID__c;
        result.put('cvId', cvId);

        List<ContentVersion> cvs = [SELECT ContentSize FROM ContentVersion WHERE Id = :cvId LIMIT 1];
        if (cvs.isEmpty()) return result;
        result.put('size', cvs[0].ContentSize);

        if (cvs[0].ContentSize > 4000000) {
            try {
                result.put('downloadUrl', getOrCreateContentDistributionUrl(cvId, 'Sign-'));
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    '[GuestSigningApi] CD provisioning failed: ' + e.getMessage());
            }
        }
        return result;
    }

    @AuraEnabled
    public static String getS3PreviewUrlSecure(String token, String sessionToken) {
        Signer__c signer = requireVerifiedSignerForToken(token, sessionToken);

        List<Agreement_Document__c> docs = [
            SELECT S3_Document_ID__c, S3_Preview_URL__c
            FROM Agreement_Document__c
            WHERE Agreement__c = :signer.Agreement__c
              AND Document_Type__c = 'Original'
              AND S3_Document_ID__c != null
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (docs.isEmpty()) return null;
        String s3DocId = docs[0].S3_Document_ID__c;
        if (String.isBlank(s3DocId)) return null;

        String s3Url;
        try {
            String fresh = AgreementServiceGuest.getS3PresignedUrlForDoc(s3DocId);
            s3Url = String.isNotBlank(fresh) ? fresh : docs[0].S3_Preview_URL__c;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                '[GuestSigningApi] Lambda getUrl failed: ' + e.getMessage());
            s3Url = docs[0].S3_Preview_URL__c;
        }

        if (String.isBlank(s3Url)) return null;

        // Return a READY-TO-USE PDFPreview iframe URL (namespace-safe path), not
        // the bare S3 URL — see pdfPreviewBase().
        return pdfPreviewBase() + '?pdfUrl='
            + EncodingUtil.urlEncode(s3Url, 'UTF-8')
            + '&ts=' + System.currentTimeMillis();
    }

    /**
     * Same signer-validation and S3 doc lookup as getS3PreviewUrlSecure, but
     * returns the RAW presigned S3 URL (bytes-fetchable) instead of wrapping it
     * in a PDFPreview Visualforce page. cacheable=false because presigned S3
     * URLs are time-limited.
     */
    @AuraEnabled(cacheable=false)
    public static String getS3RawUrlSecure(String token, String sessionToken) {
        Signer__c signer = requireVerifiedSignerForToken(token, sessionToken);

        List<Agreement_Document__c> docs = [
            SELECT S3_Document_ID__c, S3_Preview_URL__c
            FROM Agreement_Document__c
            WHERE Agreement__c = :signer.Agreement__c
              AND Document_Type__c = 'Original'
              AND S3_Document_ID__c != null
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (docs.isEmpty()) return null;
        String s3DocId = docs[0].S3_Document_ID__c;
        if (String.isBlank(s3DocId)) return null;

        String s3Url;
        try {
            String fresh = AgreementServiceGuest.getS3PresignedUrlForDoc(s3DocId);
            s3Url = String.isNotBlank(fresh) ? fresh : docs[0].S3_Preview_URL__c;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                '[GuestSigningApi] Lambda getUrl failed: ' + e.getMessage());
            s3Url = docs[0].S3_Preview_URL__c;
        }

        if (String.isBlank(s3Url)) return null;

        // Return the RAW presigned S3 URL. No VF wrapper — the LWC fetches the
        // bytes directly and renders via pdf.js.
        return s3Url;
    }

    /**
     * Returns a RAW, guest-fetchable PDF URL for the signing viewer's in-LWC
     * pdf.js renderer. NO pdfPreviewBase(), NO Page.PDFPreview, NO Site prefix —
     * so it works in any subscriber org without a classic VF-serving Site.
     * cacheable=false: presigned URLs are time-limited.
     */
    @AuraEnabled(cacheable=false)
    public static String getSigningPdfUrlSecure(String token, String sessionToken) {
        Signer__c signer = requireVerifiedSignerForToken(token, sessionToken);

        // 1. S3-backed Original document → fresh presigned URL.
        List<Agreement_Document__c> s3docs = [
            SELECT S3_Document_ID__c, S3_Preview_URL__c
            FROM Agreement_Document__c
            WHERE Agreement__c = :signer.Agreement__c
              AND Document_Type__c = 'Original'
              AND S3_Document_ID__c != null
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (!s3docs.isEmpty() && String.isNotBlank(s3docs[0].S3_Document_ID__c)) {
            String s3Url;
            try {
                String fresh = AgreementServiceGuest.getS3PresignedUrlForDoc(s3docs[0].S3_Document_ID__c);
                s3Url = String.isNotBlank(fresh) ? fresh : s3docs[0].S3_Preview_URL__c;
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    '[GuestSigningApi] getSigningPdfUrl S3 presign failed: ' + e.getMessage());
                s3Url = s3docs[0].S3_Preview_URL__c;
            }
            if (String.isNotBlank(s3Url)) return s3Url;
        }

        // 2. Original ContentVersion → convert to PDF via Lambda → raw S3 URL.
        String cvId = null;
        List<Agreement_Document__c> docs = [
            SELECT Content_Version_ID__c
            FROM Agreement_Document__c
            WHERE Agreement__c = :signer.Agreement__c
              AND Document_Type__c = 'Original'
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (!docs.isEmpty() && String.isNotBlank(docs[0].Content_Version_ID__c)) {
            cvId = docs[0].Content_Version_ID__c;
        } else {
            List<ContentDocumentLink> links = [
                SELECT ContentDocument.LatestPublishedVersionId,
                       ContentDocument.Title
                FROM ContentDocumentLink
                WHERE LinkedEntityId = :signer.Agreement__c
                  AND ContentDocument.FileType IN ('PDF','DOCX','DOC','WORD')
                ORDER BY ContentDocument.CreatedDate ASC
            ];
            for (ContentDocumentLink l : links) {
                String title = l.ContentDocument.Title;
                if (!title.endsWith('- Signed Document') && !title.endsWith('Signed')) {
                    cvId = l.ContentDocument.LatestPublishedVersionId;
                    break;
                }
            }
        }
        if (String.isBlank(cvId)) return null;

        List<ContentVersion> cvs = [
            SELECT Id, FileExtension, VersionData, PathOnClient, Title, ContentSize
            FROM ContentVersion WHERE Id = :cvId LIMIT 1
        ];
        if (cvs.isEmpty()) return null;
        ContentVersion cv = cvs[0];
        String ext = cv.FileExtension != null ? cv.FileExtension.toLowerCase() : '';

        if (ext == 'pdf' || ext == 'docx' || ext == 'doc') {
            try {
                String s3Url = DocumentEditorControllerGuest.convertToPdfViaLambda(cv);
                if (String.isNotBlank(s3Url)) return s3Url;   // RAW url — no pdfPreviewBase()
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR,
                    '[GuestSigningApi] getSigningPdfUrl conversion failed: ' + e.getMessage());
                throw new AuraHandledException(
                    'Could not prepare document for preview. Please contact support.'
                );
            }
        }

        // 3. Nothing usable.
        return null;
    }

    /**
     * Namespace-correct path to the PDFPreview Visualforce page for a GUEST on
     * the Experience site, e.g. '/signvforcesite/apex/PDFPreview'.
     * The prefix is read from SignForce_Admin_Config__c (Site_VF_Path_Prefix__c)
     * when present so subscribers can set their own, falling back to the dev value.
     */
    @TestVisible
    private static String SITE_VF_PREFIX_OVERRIDE;
    private static String pdfPreviewBase() {
        String prefix = SITE_VF_PREFIX_OVERRIDE;
        if (String.isBlank(prefix)) {
            // Subscriber-configured VF path prefix (org-specific — the classic
            // Site prefix under which the LWR site serves the VF page to guests).
            try {
                SignForce_Admin_Config__c cs = SignForce_Admin_Config__c.getOrgDefaults();
                if (cs != null) prefix = cs.Site_VF_Path_Prefix__c;
            } catch (Exception e) { /* fall through to default */ }
        }
        if (String.isBlank(prefix)) prefix = '/signvforcesite'; // last-resort (build-org) default
        prefix = prefix.trim();
        if (!prefix.startsWith('/')) prefix = '/' + prefix;
        return prefix + Page.PDFPreview.getUrl();
    }

    @AuraEnabled
    public static Map<String, Object> getPdfFileInfoSecure(String token, String sessionToken, Id contentVersionId) {
        requireVerifiedSignerForToken(token, sessionToken);
        requireContentVersionForToken(token, contentVersionId);

        ContentVersion cv = [
            SELECT ContentSize, ContentDocumentId
            FROM ContentVersion WHERE Id = :contentVersionId LIMIT 1
        ];
        Map<String, Object> result = new Map<String, Object>();
        result.put('size', cv.ContentSize);
        result.put('isLarge', cv.ContentSize > 4000000);

        if (cv.ContentSize > 4000000) {
            try {
                result.put('downloadUrl', getOrCreateContentDistributionUrl(contentVersionId, 'Preview-'));
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    '[GuestSigningApi] CD provisioning failed: ' + e.getMessage());
            }
        }
        return result;
    }

    // Max document size we will inline as base64 through a synchronous @AuraEnabled
    // method. Synchronous Apex heap is 6 MB and base64 inflates ~1.33x, so we cap
    // the source bytes well below that. Larger docs fall back to the URL path.
    private static final Integer MAX_INLINE_BYTES = 2500000;

    /**
     * Returns the Original document as base64 PDF bytes for in-browser pdf.js
     * rendering on the guest signing portal. Does NOT use ContentDistribution
     * (guests can't create it in subscriber orgs):
     *   - native PDF  → return VersionData bytes directly (no Lambda at all)
     *   - DOCX/DOC    → Lambda converts to a PDF on S3, then we proxy those bytes
     *   - too large   → return null so the LWC uses the presigned-S3 URL path
     */
    @AuraEnabled
    public static String proxyPdfViaLambdaSecure(String token, String sessionToken, Id contentVersionId) {
        requireVerifiedSignerForToken(token, sessionToken);
        requireContentVersionForToken(token, contentVersionId);

        List<ContentVersion> cvs = [
            SELECT Id, FileExtension, VersionData, ContentSize, Title, PathOnClient
            FROM ContentVersion WHERE Id = :contentVersionId LIMIT 1
        ];
        if (cvs.isEmpty()) {
            throw new AuraHandledException('Document not found.');
        }
        ContentVersion cv = cvs[0];
        String ext = cv.FileExtension != null ? cv.FileExtension.toLowerCase() : '';

        // Too big to inline safely → let the LWC fall back to the S3 URL path.
        if (cv.ContentSize != null && cv.ContentSize > MAX_INLINE_BYTES) {
            return null;
        }

        // Native PDF → return the bytes directly. No Lambda, no ContentDistribution.
        if (ext == 'pdf') {
            return EncodingUtil.base64Encode(cv.VersionData);
        }

        // DOCX/DOC → Lambda converts to a PDF on S3, then proxy those bytes back
        // (server-side download → base64). Still no ContentDistribution.
        if (ext == 'docx' || ext == 'doc') {
            String s3Url = DocumentEditorControllerGuest.convertToPdfViaLambda(cv);
            if (String.isBlank(s3Url)) return null;
            return proxyUrlBytesViaLambda(s3Url);
        }

        return null;
    }

    /**
     * S3-only Original documents (Tier2/Tier3) have NO Salesforce ContentVersion,
     * so proxyPdfViaLambdaSecure can't help. Here the Lambda fetches the presigned
     * S3 URL SERVER-SIDE (it holds the AWS keys) and returns the bytes as base64,
     * so the browser never has to reach S3 directly — which the Experience-site
     * CSP blocks. Returns null when there is no S3-backed Original.
     */
    @AuraEnabled
    public static String proxyS3PdfViaLambdaSecure(String token, String sessionToken) {
        Signer__c signer = requireVerifiedSignerForToken(token, sessionToken);

        List<Agreement_Document__c> s3docs = [
            SELECT S3_Document_ID__c, S3_Preview_URL__c
            FROM Agreement_Document__c
            WHERE Agreement__c = :signer.Agreement__c
              AND Document_Type__c = 'Original'
              AND S3_Document_ID__c != null
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (s3docs.isEmpty() || String.isBlank(s3docs[0].S3_Document_ID__c)) {
            return null;
        }

        String s3Url;
        try {
            String fresh = AgreementServiceGuest.getS3PresignedUrlForDoc(s3docs[0].S3_Document_ID__c);
            s3Url = String.isNotBlank(fresh) ? fresh : s3docs[0].S3_Preview_URL__c;
        } catch (Exception e) {
            s3Url = s3docs[0].S3_Preview_URL__c;
        }
        if (String.isBlank(s3Url)) return null;

        return proxyUrlBytesViaLambda(s3Url);
    }

    /** Guest: fetch a cloud-stored Original's bytes in byte-range chunks. */
    @AuraEnabled
    public static Map<String, Object> getCloudDocChunkSecure(String token, String sessionToken,
                                                             Integer rangeStart, Integer rangeLen) {
        Signer__c signer = requireVerifiedSignerForToken(token, sessionToken);
        List<Agreement_Document__c> docs = [
            SELECT Cloud_File_Id__c, Cloud_Provider__c
            FROM Agreement_Document__c
            WHERE Agreement__c = :signer.Agreement__c AND Document_Type__c = 'Original'
            AND Storage_Type__c = 'Cloud' AND Cloud_File_Id__c != null
            ORDER BY CreatedDate DESC LIMIT 1
        ];
        if (docs.isEmpty()) return null;
        HttpRequest req = new HttpRequest();
        req.setEndpoint(SignForceConfigServiceGuest.getLambdaEndpoint());
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(120000);
        req.setBody(JSON.serialize(new Map<String, Object>{
            'action'     => 'downloadFromCloud',
            'orgId'      => UserInfo.getOrganizationId(),
            'provider'   => docs[0].Cloud_Provider__c,
            'fileId'     => docs[0].Cloud_File_Id__c,
            'rangeStart' => rangeStart,
            'rangeLen'   => rangeLen
        }));
        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            throw new AuraHandledException('Cloud fetch failed: HTTP ' + res.getStatusCode());
        }
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        if (body.get('success') != true) {
            throw new AuraHandledException('Cloud fetch failed: ' + body.get('message'));
        }
        return new Map<String, Object>{ 'base64' => body.get('pdfBase64'), 'size' => body.get('size') };
    }

    /**
     * Sends a presigned/public file URL to the Lambda's `proxyUrl` route, which
     * downloads it server-side and returns the PDF as base64. Shared by the
     * DOCX-conversion and S3-only render paths. No ContentDistribution involved.
     */
    private static String proxyUrlBytesViaLambda(String fileUrl) {
        if (String.isBlank(fileUrl)) return null;

        Http http = new Http();
        HttpRequest req = new HttpRequest();
        req.setEndpoint(SignForceConfigServiceGuest.getLambdaEndpoint());
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(120000);
        req.setBody(JSON.serialize(new Map<String, String>{ 'proxyUrl' => fileUrl }));

        HttpResponse res = http.send(req);
        if (res.getStatusCode() == 200) {
            Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            return (String) result.get('pdfBase64');
        }
        String body = res.getBody();
        throw new AuraHandledException(
            'Document proxy failed: HTTP ' + res.getStatusCode() + ' '
            + (body != null ? body.substring(0, Math.min(300, body.length())) : '')
        );
    }

    // ═════════════════════════════════════════════════════════════════════
    //  SIGNATURE METHODS
    // ═════════════════════════════════════════════════════════════════════

    @AuraEnabled
    public static Map<String, Object> getSavedSignatureSecure(String token, String sessionToken) {
        Signer__c signer = requireVerifiedSignerForToken(token, sessionToken);
        return SignatureService.getSavedSignature(signer.Email__c);
    }

    @AuraEnabled
    public static void saveSignatureSecure(
        String token, String sessionToken, String signatureData, String signatureType, String fontFamily
    ) {
        Signer__c signer = requireVerifiedSignerForToken(token, sessionToken);
        SignatureService.saveSignature(signer.Email__c, signatureData, signatureType, fontFamily);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  BRANDING (public, no token needed)
    // ═════════════════════════════════════════════════════════════════════

    @AuraEnabled(cacheable=true)
    public static Map<String, String> getBrandingForGuest() {
        return BrandingServiceGuest.getBrandingForLWC();
    }

    // ═════════════════════════════════════════════════════════════════════
    //  INTERNAL (LOGGED-IN USER) METHODS
    // ═════════════════════════════════════════════════════════════════════
    //
    // SECURITY — read before adding anything here.
    //
    // Apex class access is granted per CLASS, and the public site's GUEST user
    // holds access to this class. Every method in this section is therefore
    // reachable by an anonymous visitor unless it refuses them itself. The rule:
    //
    //
    // Nothing in this section takes a signing token; none of it is safe for a
    // guest. GuestSigningApiInternalGuardTest calls every method as a guest and
    // fails the build if one of them gets past the guard — add a line there for
    // each method you add here.
    //
    // The business logic stays in its original class (single source of truth,
    // including the static flags the triggers read); these are guarded entry
    // points for the LWCs.

    // ── AgreementController ───────────────────────────────────────────────

    // ── SalesforceChunkUpload ─────────────────────────────────────────────

    // ── SignForceBulkSend ─────────────────────────────────────────────────

    // ═════════════════════════════════════════════════════════════════════
    //  PRIVATE HELPERS
    // ═════════════════════════════════════════════════════════════════════

    private static String getOrCreateContentDistributionUrl(Id cvId, String namePrefix) {
        List<ContentDistribution> existing = [
            SELECT ContentDownloadUrl FROM ContentDistribution
            WHERE ContentVersionId = :cvId LIMIT 1
        ];
        if (!existing.isEmpty()) {
            return existing[0].ContentDownloadUrl;
        }

        ContentDistribution dist = new ContentDistribution();
        dist.Name = namePrefix + cvId;
        dist.ContentVersionId = cvId;
        dist.PreferencesAllowViewInBrowser = true;
        dist.PreferencesLinkLatestVersion = false;
        dist.PreferencesNotifyOnVisit = false;
        dist.PreferencesPasswordRequired = false;
        dist.PreferencesAllowOriginalDownload = true;
        insert dist;

        ContentDistribution created = [
            SELECT ContentDownloadUrl FROM ContentDistribution WHERE Id = :dist.Id
        ];
        return created.ContentDownloadUrl;
    }

    // ═════════════════════════════════════════════════════════════════════
    //  INLINED GUEST AUTHORIZATION  (copied from SignForceAuthz — without
    //  sharing). Guest Users have no sharing rules, so every guest-reachable
    //  call proves: token resolves to a real, non-expired, non-revoked Signer,
    //  the claimed scope matches that signer, and (for sensitive surfaces) the
    //  caller holds the session token bound to the first tab that opened the
    //  link. All denials throw AuraHandledException with a generic message.
    // ═════════════════════════════════════════════════════════════════════

    // Single user-visible denial message. Specific reasons are debug-logged
    // server-side but never sent to the client, to avoid token-probing oracles.
    private static final String SAFE_DENY_MESSAGE =
        'Access denied. Your signing link may be invalid, expired, or already used.';

    // Distinct message for a missing/mismatched SESSION (not the token). The LWC
    // keys off this EXACT string to show the "session timed out" screen — do not
    // change the literal value.
    private static final String SESSION_REQUIRED_MESSAGE = 'SESSION_REQUIRED';

    // Per-transaction cache so a single LWC turn making 3-4 calls only hits SOQL
    // once. Keyed by token string.
    private static Map<String, Signer__c> tokenCache = new Map<String, Signer__c>();

    /**
     * Resolve a token to its Signer__c, or throw. Validates: token format, token
     * exists, not manually expired, not past the 48h window, view count under
     * cap, signer not already signed/declined. Does NOT increment view count.
     */
    private static Signer__c requireSignerForToken(String token) {
        if (String.isBlank(token) || token.length() < 10) {
            denyWithLog('Token blank or too short');
        }

        if (tokenCache.containsKey(token)) {
            return tokenCache.get(token);
        }

        List<Signer__c> signers = [
            SELECT Id, Email__c, Agreement__c, Status__c,
                   Token_Created_Date__c, Token_Expired__c, Token_View_Count__c,
                   Session_Token_Hash__c, Session_Bound_At__c
            FROM Signer__c
            WHERE Access_Token__c = :token
            LIMIT 1
        ];

        if (signers.isEmpty()) {
            denyWithLog('No signer for token');
        }

        Signer__c signer = signers[0];

        if (signer.Token_Expired__c == true) {
            denyWithLog('Token revoked: ' + signer.Id);
        }
        if (signer.Status__c == 'Signed') {
            denyWithLog('Signer already signed: ' + signer.Id);
        }
        if (signer.Status__c == 'Declined') {
            denyWithLog('Signer declined: ' + signer.Id);
        }

        // 48h hard window. Matches AgreementService.TOKEN_EXPIRY_HOURS.
        if (signer.Token_Created_Date__c != null) {
            DateTime expiryTime = signer.Token_Created_Date__c.addHours(48);
            if (DateTime.now() > expiryTime) {
                denyWithLog('Token past 48h: ' + signer.Id);
            }
        }

        Decimal viewCount = signer.Token_View_Count__c != null ? signer.Token_View_Count__c : 0;
        if (viewCount >= 50) {
            denyWithLog('Token view cap exceeded: ' + signer.Id);
        }

        tokenCache.put(token, signer);
        return signer;
    }

    /**
     * Drop any cached copy of this token's signer. Called after mutating a
     * signer's session fields (see startSigningSession) so a later verify in the
     * SAME transaction re-queries the fresh row instead of a stale cached one.
     */
    private static void invalidateToken(String token) {
        if (String.isNotBlank(token)) {
            tokenCache.remove(token);
        }
    }

    /**
     * Token validity PLUS a valid bound session token. Gate for every sensitive
     * guest surface (signer load, document, completion). A caller without the
     * matching token — a second window, a forwarded link, another device — fails
     * with SESSION_REQUIRED so the LWC shows "session timed out".
     */
    private static Signer__c requireVerifiedSignerForToken(String token, String sessionToken) {
        Signer__c signer = requireSignerForToken(token);

        if (String.isBlank(sessionToken) || String.isBlank(signer.Session_Token_Hash__c)) {
            denySession('No bound session: ' + signer.Id);
        }
        if (sha256Hex(sessionToken) != signer.Session_Token_Hash__c) {
            denySession('Session token mismatch: ' + signer.Id);
        }
        return signer;
    }

    /**
     * Post-signing CERTIFICATE render authz. Same security as
     * requireVerifiedSignerForToken (valid token + bound session) with ONE
     * deliberate difference: it does NOT reject a signer whose Status__c is
     * already 'Signed' — the cert renders the instant completeSigning succeeds,
     * by which point markSigned has flipped this signer to 'Signed'.
     */
    private static Signer__c requireVerifiedSignerForCertRender(String token, String sessionToken) {
        if (String.isBlank(token) || token.length() < 10) {
            denyWithLog('Token blank or too short (cert render)');
        }

        List<Signer__c> signers = [
            SELECT Id, Email__c, Agreement__c, Status__c,
                   Token_Created_Date__c, Token_Expired__c, Token_View_Count__c,
                   Session_Token_Hash__c, Session_Bound_At__c
            FROM Signer__c
            WHERE Access_Token__c = :token
            LIMIT 1
        ];
        if (signers.isEmpty()) {
            denyWithLog('No signer for token (cert render)');
        }
        Signer__c signer = signers[0];

        if (signer.Token_Expired__c == true) {
            denyWithLog('Token revoked (cert render): ' + signer.Id);
        }
        // NO 'already signed' rejection here — the signer IS signed at this
        // point; that is exactly when the certificate must render.
        if (signer.Status__c == 'Declined') {
            denyWithLog('Signer declined (cert render): ' + signer.Id);
        }
        if (signer.Token_Created_Date__c != null) {
            DateTime expiryTime = signer.Token_Created_Date__c.addHours(48);
            if (DateTime.now() > expiryTime) {
                denyWithLog('Token past 48h (cert render): ' + signer.Id);
            }
        }
        Decimal viewCount = signer.Token_View_Count__c != null ? signer.Token_View_Count__c : 0;
        if (viewCount >= 50) {
            denyWithLog('Token view cap exceeded (cert render): ' + signer.Id);
        }

        // Bound-session check — identical to requireVerifiedSignerForToken.
        if (String.isBlank(sessionToken) || String.isBlank(signer.Session_Token_Hash__c)) {
            denySession('No bound session (cert render): ' + signer.Id);
        }
        if (sha256Hex(sessionToken) != signer.Session_Token_Hash__c) {
            denySession('Session token mismatch (cert render): ' + signer.Id);
        }
        return signer;
    }

    /**
     * Verify a list of Signature_Field__c IDs all belong to the agreement the
     * token's signer is on, AND all are assigned to that signer. Returns the
     * field-id set so callers can short-circuit bad inputs without re-querying.
     */
    private static Set<Id> requireFieldsBelongToSigner(String token, Set<Id> fieldIds) {
        if (fieldIds == null || fieldIds.isEmpty()) return new Set<Id>();
        Signer__c signer = requireSignerForToken(token);

        List<Signature_Field__c> ok = [
            SELECT Id
            FROM Signature_Field__c
            WHERE Id IN :fieldIds
              AND Agreement__c = :signer.Agreement__c
              AND Assigned_Signer__c = :signer.Id
        ];

        if (ok.size() != fieldIds.size()) {
            denyWithLog('Field-scope mismatch: claimed=' + fieldIds.size() + ' allowed=' + ok.size() + ' signer=' + signer.Id);
        }

        Set<Id> result = new Set<Id>();
        for (Signature_Field__c f : ok) result.add(f.Id);
        return result;
    }

    /**
     * Verify a ContentVersion ID actually belongs to a document on the agreement
     * the token is for. Without this any guest could request any ContentVersion
     * in the org by guessing the 18-char ID.
     */
    private static void requireContentVersionForToken(String token, Id contentVersionId) {
        Signer__c signer = requireSignerForToken(token);

        List<Agreement_Document__c> direct = [
            SELECT Id FROM Agreement_Document__c
            WHERE Agreement__c = :signer.Agreement__c
              AND Content_Version_ID__c = :((String) contentVersionId)
            LIMIT 1
        ];
        if (!direct.isEmpty()) return;

        List<ContentVersion> cvs = [
            SELECT ContentDocumentId FROM ContentVersion
            WHERE Id = :contentVersionId LIMIT 1
        ];
        if (cvs.isEmpty()) denyWithLog('CV not found: ' + contentVersionId);

        List<ContentDocumentLink> links = [
            SELECT Id FROM ContentDocumentLink
            WHERE ContentDocumentId = :cvs[0].ContentDocumentId
              AND LinkedEntityId = :signer.Agreement__c
            LIMIT 1
        ];
        if (links.isEmpty()) {
            denyWithLog('CV not linked to signer agreement: cv=' + contentVersionId + ' agr=' + signer.Agreement__c);
        }
    }

    private static String sha256Hex(String input) {
        Blob h = Crypto.generateDigest('SHA-256', Blob.valueOf(input));
        return EncodingUtil.convertToHex(h);
    }

    /** Log the real reason server-side, throw the safe message client-side. */
    private static void denyWithLog(String reason) {
        System.debug(LoggingLevel.WARN, '[GuestSigningApi] DENY: ' + reason);
        throw new AuraHandledException(SAFE_DENY_MESSAGE);
    }

    /** Session-specific denial: distinct message so the LWC shows "session timed out". */
    private static void denySession(String reason) {
        System.debug(LoggingLevel.WARN, '[GuestSigningApi] SESSION DENY: ' + reason);
        throw new AuraHandledException(SESSION_REQUIRED_MESSAGE);
    }

    // ═════════════════════════════════════════════════════════════════════
    //  INLINED AUDIT TRAIL  (copied from AuditTrailService — without sharing).
    //  Inserts Signing_Event__c rows best-effort; a logging failure must NEVER
    //  break the signing flow it is recording.
    // ═════════════════════════════════════════════════════════════════════

    private static void auditLog(Id agreementId, String action, String signerEmail,
                                 String ipAddress, String userAgent, String notes) {
        try {
            Signing_Event__c evt = new Signing_Event__c();
            evt.Agreement__c = agreementId;
            evt.Action__c = action;
            evt.Signer_Email__c = signerEmail;
            evt.IP_Address__c = ipAddress;
            evt.User_Agent__c = userAgent;
            evt.Notes__c = (notes != null && notes.length() > 255)
                ? notes.substring(0, 255) : notes;
            evt.Event_Timestamp__c = DateTime.now();
            if (!Schema.sObjectType.Signing_Event__c.isCreateable()) {
                throw new SignForceFLS.SignForceFLSException(
                    'Insufficient access to create Signing Event records.');
            }
            insert evt;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'GuestSigningApi.auditLog failed (non-fatal): ' + e.getMessage());
        }
    }

    private static void auditLog(Id agreementId, String action, String signerEmail,
                                 String ipAddress, String userAgent) {
        try {
            Signing_Event__c evt = new Signing_Event__c();
            evt.Agreement__c = agreementId;
            evt.Action__c = action;
            evt.Signer_Email__c = signerEmail;
            evt.IP_Address__c = ipAddress;
            evt.User_Agent__c = userAgent;
            evt.Event_Timestamp__c = DateTime.now();
            if (!Schema.sObjectType.Signing_Event__c.isCreateable()) {
                throw new SignForceFLS.SignForceFLSException(
                    'Insufficient access to create Signing Event records.');
            }
            insert evt;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'GuestSigningApi.auditLog failed (non-fatal): ' + e.getMessage());
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    //  INTERNAL-USER GUARD
    // ─────────────────────────────────────────────────────────────────────

    private static final String INTERNAL_DENY_MESSAGE =
        'You do not have access to this action.';

    // Test seam: lets a unit test present the running user as a guest without
    // needing a site (and its guest licence) to exist in the org.

    // One decision per source class per transaction.

    // ═════════════════════════════════════════════════════════════════════
    //  ELEVATED HELPERS FOR GUEST-CONTEXT CALLERS
    //  Guest-facing classes stay `with sharing`; the work that needs
    //  elevation runs HERE, in this one `without sharing` class.
    // ═════════════════════════════════════════════════════════════════════

    /** Post-completion certificate regeneration. Runs as the guest signer. */
    public static void completionCertPhase(Id agreementId) {
        try {
            SignedAgreementPDFController.generateAndAttachPDF(agreementId);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'CompletionChain[CERT] failed (non-fatal): ' + e.getMessage());
        }
    }

    /** Post-completion cloud push + completion emails. Runs as the guest signer. */
    public static void completionEmailPhase(Id agreementId) {
        try {
            IntegrationServiceGuest.pushAgreementDocuments(agreementId);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'CompletionChain[EMAIL] cloud push failed: ' + e.getMessage());
        }
        try {
            AgreementServiceGuest.sendCompletionEmailsPublic(agreementId);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'CompletionChain[EMAIL] FAILED: ' + e.getMessage()
                + ' | Stack: ' + e.getStackTraceString());
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    //  PDFPreview page data access (called from PDFPreviewController's
    //  @RemoteAction methods, which stay `with sharing`).
    // ─────────────────────────────────────────────────────────────────────

    public static String pdfBase64(String contentVersionId) {
        ContentVersion cv = [
            SELECT Id, VersionData FROM ContentVersion
            WHERE Id = :contentVersionId LIMIT 1
        ];
        return EncodingUtil.base64Encode(cv.VersionData);
    }

    public static String pdfDistributionUrl(String contentVersionId) {
        List<ContentDistribution> dists = [
            SELECT ContentDownloadUrl FROM ContentDistribution
            WHERE ContentVersionId = :contentVersionId LIMIT 1
        ];
        return dists.isEmpty() ? null : dists[0].ContentDownloadUrl;
    }

    public static Map<String, Object> pdfInfo(String contentVersionId) {
        ContentVersion cv = [
            SELECT ContentSize, FileType, ContentDocumentId
            FROM ContentVersion WHERE Id = :contentVersionId LIMIT 1
        ];
        Integer chunkSize = 3000000;
        Map<String, Object> info = new Map<String, Object>();
        info.put('size', cv.ContentSize);
        info.put('fileType', cv.FileType);
        info.put('totalChunks', (Integer) Math.ceil((Decimal) cv.ContentSize / chunkSize));
        info.put('chunkSize', chunkSize);
        if (cv.ContentSize > 4500000) {
            info.put('distributionUrl', pdfCreateDistributionUrl(contentVersionId));
        }
        return info;
    }

    public static String pdfCreateDistributionUrl(String contentVersionId) {
        try {
            return getOrCreateContentDistributionUrl((Id) contentVersionId, 'PDFPreview-');
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'PDFPreview: ContentDistribution failed: ' + e.getMessage());
            return null;
        }
    }

    public static String pdfChunk(String contentVersionId, Integer chunkIndex) {
        ContentVersion cv = [
            SELECT VersionData FROM ContentVersion
            WHERE Id = :contentVersionId LIMIT 1
        ];
        Blob fullData = cv.VersionData;
        Integer chunkSize = 3000000;
        Integer startByte = chunkIndex * chunkSize;
        Integer endByte = Math.min(startByte + chunkSize, fullData.size());
        if (startByte >= fullData.size()) return '';
        String fullBase64 = EncodingUtil.base64Encode(fullData);
        Integer b64Start = (startByte / 3) * 4;
        Integer b64End = Math.min((Integer) Math.ceil((Decimal) endByte / 3) * 4, fullBase64.length());
        return fullBase64.substring(b64Start, b64End);
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Elevated reads for the PDF-rendering Visualforce controllers.
    //  Those pages render as the Site Guest User, who has no sharing access
    //  to the records, so their queries live here instead.
    // ─────────────────────────────────────────────────────────────────────

    /** Saved signature for a signer's email. Shared by all PDF controllers. */
    public static List<Saved_Signature__c> savedSignatureFor(String email) {
        return [
            SELECT Signature_Data__c, Signature_Type__c, Font_Family__c
            FROM Saved_Signature__c WHERE Email__c = :email LIMIT 1
        ];
    }

    /** Audit-trail rows for an agreement. Shared by the PDF controllers. */
    public static List<Signing_Event__c> auditRowsFor(Id agreementId) {
        return [
            SELECT Action__c, Signer_Email__c, Event_Timestamp__c, IP_Address__c
            FROM Signing_Event__c WHERE Agreement__c = :agreementId
            ORDER BY Event_Timestamp__c ASC
        ];
    }

    /** Org time zone. */
    public static String orgTimeZone() {
        return [SELECT TimeZoneSidKey FROM Organization LIMIT 1].TimeZoneSidKey;
    }

    /** Display name of a user (the agreement's creator). */
    public static List<User> userName(Id userId) {
        return [SELECT Name FROM User WHERE Id = :userId LIMIT 1];
    }

    // ── SignedDocumentPDF page ──

    // The SignedDocumentPDF / StampedAgreementPDF data-access helpers (sdAgreement, sdOriginalDoc,
    // sdContentVersion, sdFields, stAgreement, stSigners, stSignatureField, stValueFields) moved to
    // GuestSigningApiInternal: they are only called by internal-user PDF controllers.

    // ── StampedAgreementPDF page ──

    // ── SignedAgreementPDF page (signing certificate) ──

    public static List<Agreement__c> saAgreement(Id agreementId) {
        return [
            SELECT Id, Name, Agreement_Type__c, Status__c,
                   Completed_Date__c, Sent_Date__c, Envelope_ID__c,
                   Owner.Name, Owner.Email, Message_to_Signers__c,
                   CreatedById
            FROM Agreement__c WHERE Id = :agreementId LIMIT 1
        ];
    }

    public static List<Signer__c> saSigners(Id agreementId) {
        return [
            SELECT Id, Name, Email__c, Status__c, Signed_Date__c,
                   Signing_Order__c, Role__c, Signature_Certificate_ID__c,
                   Signing_IP_Address__c
            FROM Signer__c
            WHERE Agreement__c = :agreementId
            ORDER BY Signing_Order__c ASC NULLS LAST
        ];
    }

    public static List<Signature_Field__c> saSignatureFields(Id agreementId) {
        return [
            SELECT Assigned_Signer__c, Field_Value__c, Field_Type__c
            FROM Signature_Field__c
            WHERE Agreement__c = :agreementId
              AND Field_Type__c IN ('Signature', 'Initial')
              AND Is_Completed__c = true
        ];
    }

    public static Agreement__c saAgreementName(Id agreementId) {
        return [SELECT Name FROM Agreement__c WHERE Id = :agreementId LIMIT 1];
    }

    public static Signer__c saSignerIp(Id signerId) {
        return [
            SELECT Signing_IP_Address__c, Signature_Certificate_ID__c
            FROM Signer__c WHERE Id = :signerId LIMIT 1
        ];
    }

    public static List<Signing_Event__c> saDocumentSignedEvent(Id agreementId) {
        return [
            SELECT IP_Address__c FROM Signing_Event__c
            WHERE Agreement__c = :agreementId AND Action__c = 'Document Signed'
            ORDER BY Event_Timestamp__c DESC LIMIT 1
        ];
    }

    /**
     * Replace the agreement's 'Signed' certificate document with a fresh one.
     * Elevated because this runs while the signer is the Site Guest User.
     */
    public static void saAttachCertificate(Id agreementId, String fileTitle, Blob pdfBlob) {
        List<Agreement_Document__c> oldDocs = [
            SELECT Id FROM Agreement_Document__c
            WHERE Agreement__c = :agreementId AND Document_Type__c = 'Signed'
        ];
        // CRUD: a missing delete right must not throw - the prior Signed row
        // just remains.
        if (!oldDocs.isEmpty() && Schema.sObjectType.Agreement_Document__c.isDeletable()) {
            delete oldDocs;
        }

        ContentVersion cv = new ContentVersion();
        cv.Title = fileTitle;
        cv.PathOnClient = fileTitle + '.pdf';
        cv.VersionData = pdfBlob;
        cv.FirstPublishLocationId = agreementId;
        insert cv;

        ContentVersion inserted = [SELECT Id FROM ContentVersion WHERE Id = :cv.Id];

        Agreement_Document__c doc = new Agreement_Document__c();
        doc.Agreement__c = agreementId;
        doc.Content_Version_ID__c = inserted.Id;
        doc.Document_Type__c = 'Signed';
        insert doc;
    }
}