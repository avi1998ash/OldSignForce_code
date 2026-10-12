/**
 * AgreementControllerGuest — token-authenticated entry points for the guest
 * signing portal (signingViewer, signatureCanvas LWCs).
 */
public without sharing class AgreementControllerGuest {

    // ═══════════════════════════════════════════════════════════
    //  STAMPING COORDINATION STATE (guest-only)
    //
    //  Both flags below are set ONLY by the guest signing path (this class and
    //  GuestSigningApi), never by internal users. They used to live on
    //  AgreementController; they moved here so that class (with sharing) holds no
    //  guest-only state and the guest classes no longer reach into it.
    //  AgreementTrigger reads suppressCompletionStampTrigger from here; the stamp
    //  copy in this class reads suppressCloudStampUpload.
    // ═══════════════════════════════════════════════════════════

    /**
     * Set by the guest signing path before it commits the Completed status, so
     * AgreementTrigger knows not to queue a stamp of its own.
     *
     * Guest signing already queues stamping itself (it owns the completion email
     * that follows), and the trigger fires from the SAME transaction — so both
     * used to queue an @future job. The two ran concurrently, both passed the
     * "already stamped?" guard because neither had committed a Stamped row yet,
     * and both called the backend. Each callout wrote its own file into the
     * customer's Drive, which is why a completed agreement showed two identical
     * stamped PDFs there. Salesforce looked clean because the second run deleted
     * the first Stamped row — but deleting the row does not delete the Drive file.
     *
     * A static is the right tool precisely because the trigger runs in the same
     * transaction as the code that sets it. In-org signing never sets it, so the
     * trigger keeps stamping for that path exactly as before.
     */
    public static Boolean suppressCompletionStampTrigger = false;

    /**
     * Set by the mid-flow re-stamp (signer N of M, M not yet reached) so a
     * PARTIAL stamp is never written into the customer's cloud storage.
     *
     * Only matters for a Cloud-tier Original (>4MB, uploaded straight to Drive /
     * OneDrive). That path stamps by asking the backend to download, stamp and
     * upload in one call — the stamped file lands in the agreement's Stamped
     * folder as a side effect of stamping at all, and the backend always creates
     * a new file, it never versions by name. So a two-signer agreement got two
     * files: the partial one after signer 1 and the complete one after signer 2,
     * leaving a half-signed copy of a legal document sitting in their folder.
     *
     * Suppressing the mid-flow stamp entirely is the fix rather than suppressing
     * only its upload, because for this tier the upload IS the storage — there is
     * no local copy to keep. Nothing depends on the intermediate: the next signer
     * sees earlier signatures from getOtherCompletedFieldsSecure, which overlays
     * the other signers' completed fields on the live document.
     *
     * The Salesforce and S3 tiers keep re-stamping mid-flow exactly as before —
     * their stamps stay inside Salesforce/S3, and the single cloud push for those
     * happens once at completion via IntegrationServiceGuest.pushAgreementDocuments.
     */
    public static Boolean suppressCloudStampUpload = false;

    /** Thrown by generateStampedPDFServerGuest (the guest-side copy of the stamping logic). */
    public class SignForceStampException extends Exception {}

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
        return SignForceSessionService.start(token);
    }

    /**
     * Called on reload to confirm the stored session token is still the bound
     * one (so a genuine refresh isn't re-gated). Returns true/false, never throws.
     */
    @AuraEnabled
    public static Boolean validateSigningSession(String token, String sessionToken) {
        return SignForceSessionService.validate(token, sessionToken);
    }

    @AuraEnabled
    public static void declineAgreementSecure(String token, String sessionToken, String reason) {
        Signer__c signer = SignForceAuthz.requireVerifiedSignerForToken(token, sessionToken);
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

            AuditTrailServiceGuest.log(s.Agreement__c, 'Consent Accepted', s.Email__c, ipAddress, userAgent);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'logConsentAccepted skipped: ' + e.getMessage());
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    //  OTP IDENTITY GATE (emailed one-time code before the document loads)
    // ─────────────────────────────────────────────────────────────────────

    /**
     * Emails the signer a one-time verification code, or refuses with the
     * remaining cooldown when one was sent under 60 seconds ago. Resolved by
     * token like the sibling methods; OTPService owns the OTP semantics
     * (cooldown, expiry, attempt cap) — this method only authorises and audits.
     */
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
            Signer__c signer = SignForceAuthz.requireVerifiedSignerForCertRender(token, sessionToken);
            SignedAgreementPDFController.generateAndAttachPDF(signer.Agreement__c, signer.Id, true);
            return new Map<String, Object>{ 'success' => true };
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'generateSigningCertificateSecure failed (non-fatal, async will retry): ' + e.getMessage());
            return new Map<String, Object>{ 'success' => false, 'message' => e.getMessage() };
        }
    }

    @AuraEnabled
    public static Map<String, Object> sendSigningOtp(String token) {
        // Each step isolated so any failure names WHICH step and surfaces the
        // real class.method:line to the LWC console — otherwise a subscriber-org
        // error (managed Apex logs are empty there) is impossible to locate.
        Signer__c signer;
        try {
            signer = SignForceAuthz.requireSignerForToken(token);
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
                AuditTrailServiceGuest.log(signer.Agreement__c, 'OTP Sent', signer.Email__c, null, null);
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
        Signer__c signer = SignForceAuthz.requireSignerForToken(token);
        Map<String, Object> result = OTPService.verifySigningOtp(signer.Id, code);
        // 'alreadyVerified' marks the idempotent re-check path (page refresh
        // after verifying) — that one must not add a second audit row.
        if (result.get('verified') == true && result.get('alreadyVerified') != true) {
            AuditTrailServiceGuest.log(signer.Agreement__c, 'OTP Verified', signer.Email__c, null, null);
        }
        return result;
    }

    /**
     * Bundled post-signing flow: mark signer signed, then queue the
     * heavy post-signing work (stamp, cert, email) in a separate
     * transaction via @future, so the HTTP callouts don't collide with
     * the DML done by markSigned() ("uncommitted work pending").
     */
    // @AuraEnabled
    // public static Map<String, Object> completeSigningSecure(
    //     String token, String ipAddress, String userAgent
    // ) {
    //     Signer__c signer = SignForceAuthz.requireSignerForToken(token);
    //     Id signerId = signer.Id;
    //     Id agreementId = signer.Agreement__c;

    //     // 1. Mark signed (must succeed — surfaces the user's action)
    //     AgreementService.markSigned(signerId, ipAddress, userAgent);

    //     // Re-read to check if all signers have signed
    //     Signer__c after = [
    //         SELECT Agreement__c, Signature_Certificate_ID__c, Agreement__r.Status__c
    //         FROM Signer__c WHERE Id = :signerId LIMIT 1
    //     ];
    //     Boolean isCompleted = (after.Agreement__r.Status__c == 'Completed');

    //     // 2. Queue async post-signing flow.
    //     // CRITICAL: markSigned() above did DML. If we tried to do Lambda
    //     // callouts inline here, we'd get "Uncommitted work pending" error.
    //     // Solution: move everything (stamp + cert + email) into @future
    //     // method that runs in a fresh transaction with no prior DML.
    //     if (isCompleted) {
    //         // CRITICAL: markSigned() above did DML. Lambda callouts in same
    //         // transaction will throw "Uncommitted work pending". The @future
    //         // method runs in a fresh transaction — same pattern as the
    //         // manual Apex script that works.
    //         try {
    //             runPostSigningFlowAsync(agreementId);
    //             System.debug('SignForce: Queued async post-signing flow for ' + agreementId);
    //         } catch (Exception e) {
    //             System.debug(LoggingLevel.ERROR,
    //                 'SignForce: Failed to queue async flow: ' + e.getMessage());
    //         }
    //     }


    //     return new Map<String, Object>{
    //         'isCompleted'   => isCompleted,
    //         'agreementId'   => agreementId,
    //         'certificateId' => after.Signature_Certificate_ID__c
    //     };
    // }

   
    @AuraEnabled
    public static Map<String, Object> completeSigningSecure(
        String token, String sessionToken, String ipAddress, String userAgent, String ipAddressV4
    ) {
        // Each sync step named so a subscriber-org 500 (managed logs are empty
        // there) surfaces WHICH step + class.method:line to the LWC console.
        Signer__c signer;
        try {
            signer = SignForceAuthz.requireVerifiedSignerForToken(token, sessionToken);
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
        suppressCompletionStampTrigger = true;
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
        suppressCloudStampUpload = true;
        try {
            generateStampedPDFServerGuest(agreementId);
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
        suppressCloudStampUpload = false;
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
                    generateStampedPDFServerGuest(agreementId);
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
                generateStampedPDFServerGuest(agreementId);
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
                AuditTrailServiceGuest.log(agreementId, 'Stamped Document Generated', 'guest@signforce.com', null, null);
            } else {
                // Reason goes in Notes__c (6-arg overload), not User_Agent__c.
                // Passing it as the 5th argument put it in the user-agent field,
                // which the record page does not show — so every stamping failure
                // looked like it had no explanation at all.
                AuditTrailServiceGuest.log(agreementId, 'Stamped Document Failed', 'guest@signforce.com', null, null,
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
            generateStampedPDFServerGuest(agreementId);
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
        Signer__c signer = SignForceAuthz.requireSignerForToken(token);
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
        Signer__c signer = SignForceAuthz.requireSignerForToken(token);
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

        Set<Id> ok = SignForceAuthz.requireFieldsBelongToSigner(token, claimedIds);

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
        Signer__c signer = SignForceAuthz.requireSignerForToken(token);

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
     * for use as iframe.src in the guest signing portal.
     *
     * Why this exists:
     *   The earlier flow returned just a ContentVersion Id and the LWC built
     *   '/apex/PDFPreview?cvId=...' itself. That works ONLY when the file is
     *   already a PDF. For DOCX/DOC originals (the common case when "Generate
     *   Document" produces a Word doc), PDF.js throws
     *   "Invalid PDF structure" — because it tries to decode DOCX bytes as PDF.
     *
     * What this does (mirrors DocumentEditorController.getPublicPreviewUrl
     * but with token-based authorization):
     *   - PDF original  → returns '/apex/PDFPreview?cvId=...'  (direct)
     *   - DOCX / DOC    → calls Lambda 'convertToPdf' → S3 presigned URL,
     *                     returns '/apex/PDFPreview?pdfUrl=<s3>'
     *   - Unknown ext   → falls back to cvId (best-effort)
     *
     * Authorization:
     *   Token is validated via SignForceAuthz.requireSignerForToken and the
     *   ContentVersion must be linked to the agreement that token belongs to.
     *   A guest cannot snoop arbitrary CV IDs because we look the CV up from
     *   the signer's agreement, not from any client input.
     */
    @AuraEnabled
    public static String getPublicPreviewUrlSecure(String token, String sessionToken) {
        Signer__c signer = SignForceAuthz.requireVerifiedSignerForToken(token, sessionToken);

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

        // Load the CV so we can branch on file extension. We need VersionData
        // and ContentSize for the Lambda call when conversion is required.
        List<ContentVersion> cvs = [
            SELECT Id, FileExtension, VersionData, PathOnClient, Title, ContentSize
            FROM ContentVersion WHERE Id = :cvId LIMIT 1
        ];
        if (cvs.isEmpty()) return null;
        ContentVersion cv = cvs[0];
        String ext = cv.FileExtension != null ? cv.FileExtension.toLowerCase() : '';

        // ─────────────────────────────────────────────────────────────────
        // CRITICAL: Guest users CANNOT use /apex/PDFPreview?cvId=...
        // ─────────────────────────────────────────────────────────────────
        // The PDFPreview page uses Visualforce.remoting (PDFPreviewController)
        // which requires a Salesforce session. Guest users on a public Site
        // don't have one. Fallback paths in the page hit:
        //   - /sfc/servlet.shepherd/version/download/{cvId}  → 401 for guests
        //   - /services/apexrest/pdfproxy                    → 401 for guests
        // PDF.js then receives an HTML/JSON error body and throws
        // "Invalid PDF structure".
        //
        // Solution: For guest users we ALWAYS route through Lambda's
        // convertToPdf action, which uploads the file to S3 and returns a
        // presigned URL. S3 presigned URLs need no Salesforce auth, so the
        // guest browser can fetch them directly via PDFPreview?pdfUrl=...
        //
        // This means PDF files also pay the Lambda round-trip cost (~1-2s)
        // for guest users — that's the price of bypassing Salesforce auth.
        // Internal users (DocumentEditorController.getPublicPreviewUrl) still
        // use the cheap cvId path because they have a session.
        if (ext == 'pdf' || ext == 'docx' || ext == 'doc') {
            try {
                String s3Url = DocumentEditorControllerGuest.convertToPdfViaLambda(cv);
                if (String.isNotBlank(s3Url)) {
                    // Page.X.getUrl() emits the namespaced path (/apex/ns__PDFPreview)
                    // in a managed package; a hardcoded '/apex/PDFPreview' would break.
                    return pdfPreviewBase() + '?pdfUrl='
                        + EncodingUtil.urlEncode(s3Url, 'UTF-8')
                        + '&ts=' + System.currentTimeMillis();
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR,
                    '[AgreementControllerGuest] Lambda conversion failed for guest preview: '
                    + e.getMessage());
                // Re-throw so the LWC can show a meaningful error rather than
                // silently falling back to the broken cvId path.
                throw new AuraHandledException(
                    'Could not prepare document for preview. Please contact support.'
                );
            }
        }

        // Unknown extension — last-resort direct path. Will likely fail for
        // guests but at least surfaces the issue.
        return pdfPreviewBase() + '?cvId=' + cvId
            + '&ts=' + System.currentTimeMillis();
    }

    @AuraEnabled
    public static Map<String, Object> getDocumentForSigningSecure(String token) {
        Signer__c signer = SignForceAuthz.requireSignerForToken(token);
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
                    '[AgreementControllerGuest] CD provisioning failed: ' + e.getMessage());
            }
        }
        return result;
    }

    @AuraEnabled
    public static String getS3PreviewUrlSecure(String token, String sessionToken) {
        Signer__c signer = SignForceAuthz.requireVerifiedSignerForToken(token, sessionToken);

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
                '[AgreementControllerGuest] Lambda getUrl failed: ' + e.getMessage());
            s3Url = docs[0].S3_Preview_URL__c;
        }

        if (String.isBlank(s3Url)) return null;

        // Return a READY-TO-USE PDFPreview iframe URL, not the bare S3 URL.
        //
        // CRITICAL: build the path with pdfPreviewBase(). In a
        // namespaced / managed-package org it emits '/apex/NSIQ_SignForce__PDFPreview'.
        // The LWC used to hardcode '/apex/PDFPreview' (no namespace) — that path
        // does not exist on the guest Experience site, so Salesforce redirects
        // the iframe to /login, whose CSP 'frame-ancestors none' blocks framing
        // and the signing document renders as a blank grey box.
        // (Same namespace-safe pattern as getPublicPreviewUrlSecure above.)
        return pdfPreviewBase() + '?pdfUrl='
            + EncodingUtil.urlEncode(s3Url, 'UTF-8')
            + '&ts=' + System.currentTimeMillis();
    }

    /**
     * Same signer-validation and S3 doc lookup as getS3PreviewUrlSecure, but
     * returns the RAW presigned S3 URL (bytes-fetchable) instead of wrapping it
     * in a PDFPreview Visualforce page.
     *
     * Why this exists:
     *   On an LWR Enhanced Experience guest site, framing the VF PDFPreview page
     *   in an <iframe> fails — the relative /apex/ URL redirects to /login and
     *   CSP 'frame-ancestors none' blocks the frame, leaving a blank document.
     *   The signingViewer LWC now renders the PDF directly with pdf.js, so it
     *   needs the raw presigned URL to fetch the PDF bytes itself.
     *
     * cacheable=false because presigned S3 URLs are time-limited; caching a
     * stale URL would yield 403s after expiry.
     */
    @AuraEnabled(cacheable=false)
    public static String getS3RawUrlSecure(String token, String sessionToken) {
        Signer__c signer = SignForceAuthz.requireVerifiedSignerForToken(token, sessionToken);

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
                '[AgreementControllerGuest] Lambda getUrl failed: ' + e.getMessage());
            s3Url = docs[0].S3_Preview_URL__c;
        }

        if (String.isBlank(s3Url)) return null;

        // Return the RAW presigned S3 URL. No VF wrapper, no Page.PDFPreview —
        // the LWC fetches the bytes directly and renders via pdf.js.
        return s3Url;
    }

    /**
     * Returns a RAW, guest-fetchable PDF URL for the signing viewer's in-LWC
     * pdf.js renderer. NO pdfPreviewBase(), NO Page.PDFPreview, NO Site prefix —
     * so it works in any subscriber org without a classic VF-serving Site.
     *
     * Resolution order:
     *   1. S3-backed Original doc → fresh presigned URL (falls back to stored
     *      S3_Preview_URL__c if the Lambda presign call fails).
     *   2. Else resolve the Original ContentVersion → Lambda convertToPdf →
     *      raw S3 URL (PDF passthrough or DOCX/DOC conversion). On conversion
     *      failure, throw a user-friendly AuraHandledException.
     *   3. Else null.
     *
     * cacheable=false: presigned URLs are time-limited.
     */
    @AuraEnabled(cacheable=false)
    public static String getSigningPdfUrlSecure(String token, String sessionToken) {
        Signer__c signer = SignForceAuthz.requireVerifiedSignerForToken(token, sessionToken);

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
                    '[AgreementControllerGuest] getSigningPdfUrl S3 presign failed: ' + e.getMessage());
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
                    '[AgreementControllerGuest] getSigningPdfUrl conversion failed: ' + e.getMessage());
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
     * the Experience site, e.g. '/signvforcesite/apex/NSIQ_SignForce__PDFPreview'.
     *
     * WHY THE SITE PREFIX: empirically verified that on this LWR Enhanced site the
     * VF page is served ONLY under the classic Site's URL path prefix
     * ('/signvforcesite') — a bare '/apex/...' returns 401→/login (CSP-blocked,
     * blank document), and the LWR community prefix ('/sign') returns 404.
     * Page.X.getUrl() supplies the '/apex/<ns>__PDFPreview' part (namespace-correct);
     * we prepend the Site path prefix.
     *
     * The prefix is read from SignForce_Config__mdt (Site_VF_Path_Prefix__c) when
     * present so subscribers can set their own, falling back to the dev value.
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
        SignForceAuthz.requireVerifiedSignerForToken(token, sessionToken);
        SignForceAuthz.requireContentVersionForToken(token, contentVersionId);

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
                    '[AgreementControllerGuest] CD provisioning failed: ' + e.getMessage());
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
     * rendering on the guest signing portal.
     *
     * IMPORTANT (managed-package portability): this path does NOT use
     * ContentDistribution. Experience Cloud GUEST users cannot create
     * ContentDistribution records in a subscriber org (the required permission is
     * not grantable to guests), so the old CD-based proxy worked in the packaging
     * org but failed in every subscriber org. Instead:
     *   - native PDF  → return VersionData bytes directly (no Lambda at all)
     *   - DOCX/DOC    → Lambda converts to a PDF on S3, then we proxy those bytes
     *   - too large   → return null so the LWC uses the presigned-S3 URL path
     */
    @AuraEnabled
    public static String proxyPdfViaLambdaSecure(String token, String sessionToken, Id contentVersionId) {
        SignForceAuthz.requireVerifiedSignerForToken(token, sessionToken);
        SignForceAuthz.requireContentVersionForToken(token, contentVersionId);

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
        Signer__c signer = SignForceAuthz.requireVerifiedSignerForToken(token, sessionToken);

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
        Signer__c signer = SignForceAuthz.requireVerifiedSignerForToken(token, sessionToken);
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
        Signer__c signer = SignForceAuthz.requireVerifiedSignerForToken(token, sessionToken);
        return SignatureService.getSavedSignature(signer.Email__c);
    }

    @AuraEnabled
    public static void saveSignatureSecure(
        String token, String sessionToken, String signatureData, String signatureType, String fontFamily
    ) {
        Signer__c signer = SignForceAuthz.requireVerifiedSignerForToken(token, sessionToken);
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

    

    // ════════════════════════════════════════════════════════════════
    //  STAMPING (guest context) — generateStampedPDFServerGuest
    //
    //  Guest-side copy of the server-side stamping logic. It is a full
    //  duplicate of AgreementController.generateStampedPDFServerInternal
    //  (and its private helpers) so each audience owns its own code path
    //  and sharing context. Queries/DML are already system-mode, so no
    //  guest-specific logic change was needed.
    // ════════════════════════════════════════════════════════════════

    public static void generateStampedPDFServerGuest(Id agreementId) {
        // NOTE: Stamping is a trusted backend assembly operation. It often runs
        // in GUEST USER context (the last signer completing via the public link),
        // and guest profiles rarely have FLS on all queried fields. The queries
        // and DML below therefore run in system mode — same approach already
        // used for the stamped ContentVersion insert (AccessLevel.SYSTEM_MODE).
        // No data is exposed to the user beyond the stamped PDF itself.
        try {
            System.debug('SignForce Stamp: Starting for agreement=' + agreementId);

            // Completion sets TWO async stamps running: the guest signing flow
            // queues one (it also sends the completion email) and AgreementTrigger
            // queues another (it is the only stamp the in-org signing path gets).
            // Both then produce a file and a Stamped row, which is why a completed
            // agreement showed two identical "Final Signed Document" entries.
            //
            // Neither path can simply be dropped — one owns the email, the other
            // owns in-org signing — so whichever arrives second stops here. The
            // check is deliberately narrow: it only skips when the agreement is
            // ALREADY Completed and a Stamped row exists that was created at or
            // after that moment, i.e. a stamp that already carries every signature.
            // Mid-flow stamps (agreement still in progress) are untouched, so no
            // signature can be lost by skipping.
            List<Agreement__c> agrCheck = [
                SELECT Status__c, Completed_Date__c FROM Agreement__c
                WHERE Id = :agreementId LIMIT 1
            ];
            if (!agrCheck.isEmpty()
                && agrCheck[0].Status__c == 'Completed'
                && agrCheck[0].Completed_Date__c != null) {
                Integer finalStamps = [
                    SELECT COUNT() FROM Agreement_Document__c
                    WHERE Agreement__c = :agreementId
                    AND Document_Type__c = 'Stamped'
                    AND CreatedDate >= :agrCheck[0].Completed_Date__c
                ];
                if (finalStamps > 0) {
                    System.debug('SignForce Stamp: final stamp already present, skipping duplicate');
                    return;
                }
            }

            List<Agreement_Document__c> origDocs = [
                SELECT Id, Content_Version_ID__c, S3_Document_ID__c, Storage_Tier__c,
                    Storage_Type__c, Cloud_File_Id__c, Cloud_Provider__c
                FROM Agreement_Document__c
                WHERE Agreement__c = :agreementId
                AND Document_Type__c = 'Original'
                ORDER BY CreatedDate DESC
                LIMIT 1
            ];
            if (origDocs.isEmpty()) {
                System.debug(LoggingLevel.ERROR, 'SignForce Stamp: No original document found for ' + agreementId);
                throw new SignForceStampException('No original document found for agreement ' + agreementId);
            }
            Agreement_Document__c origDoc = origDocs[0];
            System.debug('SignForce Stamp: Original tier=' + origDoc.Storage_Tier__c 
                + ', S3=' + origDoc.S3_Document_ID__c 
                + ', CV=' + origDoc.Content_Version_ID__c);

            Agreement__c agr = [
                SELECT Name, Envelope_ID__c
                FROM Agreement__c WHERE Id = :agreementId
            ];

            List<Signature_Field__c> fields = [
                SELECT Field_Type__c, Field_Value__c, Page_Number__c,
                    X_Position__c, Y_Position__c, Width__c, Height__c,
                    Page_Width__c, Is_Completed__c,
                    Assigned_Signer__r.Name, Assigned_Signer__r.Email__c,
                    Assigned_Signer__r.Signing_IP_Address__c, Assigned_Signer__r.Signed_Date__c,
                    Assigned_Signer__r.Signature_Certificate_ID__c
                FROM Signature_Field__c
                WHERE Agreement__c = :agreementId
                AND Is_Completed__c = true
            ];

            if (fields.isEmpty()) {
                System.debug(LoggingLevel.ERROR, 'SignForce Stamp: No completed fields. Skipping.');
                throw new SignForceStampException('No completed signature fields found');
            }
            System.debug('SignForce Stamp: ' + fields.size() + ' completed fields found');

            List<Map<String, Object>> fieldList = buildStampFieldList(fields);
            if (fieldList.isEmpty()) {
                System.debug(LoggingLevel.ERROR, 'SignForce Stamp: Field list empty after build');
                return;
            }
            System.debug('SignForce Stamp: Built ' + fieldList.size() + ' fields for Lambda');

            Map<String, Object> meta = new Map<String, Object>();
            meta.put('envelopeId', agr.Envelope_ID__c != null ? (Object)agr.Envelope_ID__c : (Object)String.valueOf(agreementId));
            meta.put('agreementName', agr.Name);
            meta.put('referencePageWidth', 762);

            // New uploads always live in Salesforce Files (Tier1, no S3), so the
            // stamped result is produced by the Lambda's base64 stamp path and
            // stored back in Salesforce — S3 is never touched. stampViaS3 remains
            // only for any legacy document that still has an S3 copy.
            Boolean isCloud = origDoc.Storage_Type__c == 'Cloud'
                && String.isNotBlank(origDoc.Cloud_File_Id__c);
            Boolean isS3 = String.isNotBlank(origDoc.S3_Document_ID__c);
            System.debug('SignForce Stamp: Routing to '
                + (isCloud ? 'stampViaCloud' : (isS3 ? 'stampViaS3' : 'stampOriginalToSalesforce')));
            if (isCloud) {
                // stampViaCloud publishes into the customer's Stamped folder, so
                // a mid-flow stamp would leave a partly-signed copy there (and a
                // second file after every signer). See suppressCloudStampUpload.
                if (suppressCloudStampUpload) {
                    System.debug('SignForce Stamp: mid-flow stamp skipped for cloud-stored original '
                        + '— only the final stamp is published to the customer\'s folder');
                    return;
                }
                stampViaCloud(agreementId, agr, origDoc, fieldList, meta);
            } else if (isS3) {
                stampViaS3(agreementId, agr, origDoc, fieldList, meta);
            } else {
                stampOriginalToSalesforce(agreementId, agr, origDoc, fieldList, meta);
            }
            
            System.debug('SignForce Stamp:Completed successfully for agreement ' + agreementId);

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'SignForce Stamp:  FAILED — ' + e.getMessage());
            System.debug(LoggingLevel.ERROR, 'SignForce Stamp: Stack — ' + e.getStackTraceString());
            throw new SignForceStampException('Stamping failed: ' + e.getMessage());
        }
    }

    /**
     * Salesforce-only stamping path (no S3): the original lives in ContentVersion,
     * so we send its bytes to the Lambda's base64 stamp endpoint, get the stamped
     * PDF back as base64, and store it straight into a new ContentVersion. Nothing
     * is written to S3. Runs in the async completion context, whose 12 MB heap
     * comfortably holds a ~4 MB file's base64 + decoded blob.
     */
    private static void stampOriginalToSalesforce(
        Id agreementId,
        Agreement__c agr,
        Agreement_Document__c origDoc,
        List<Map<String, Object>> fieldList,
        Map<String, Object> meta
    ) {
        if (String.isBlank(origDoc.Content_Version_ID__c)) {
            throw new SignForceStampException('stampOriginalToSalesforce: Original CV is blank');
        }

        // Read original bytes → base64 → Lambda base64 stamp → stamped blob.
        Blob stampedPdfBlob;
        {
            ContentVersion cv = [
                SELECT VersionData, FileExtension, PathOnClient, Title FROM ContentVersion
                WHERE Id = :origDoc.Content_Version_ID__c LIMIT 1
            ];
            String ext = cv.FileExtension == null ? '' : cv.FileExtension.toLowerCase();
            String pdfBase64;
            if (ext == 'pdf') {
                pdfBase64 = EncodingUtil.base64Encode(cv.VersionData);
            } else {
                // Generated agreements carry a DOCX original; the stamper parses
                // PDF only ("No PDF header found"). Convert to the same PDF
                // rendition the signer saw (LibreOffice is deterministic, so the
                // field coordinates captured during signing still line up).
                pdfBase64 = convertOriginalToPdfBase64(cv);
            }
            cv = null;

            String body = JSON.serialize(new Map<String, Object>{
                'pdfBase64' => pdfBase64,
                'fields'    => fieldList,
                'meta'      => meta
            });
            pdfBase64 = null;

            HttpRequest req = new HttpRequest();
            req.setEndpoint(SignForceConfigServiceGuest.getLambdaEndpoint());
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setTimeout(120000);
            req.setBody(body);
            body = null;

            HttpResponse res;
            try {
                res = new Http().send(req);
            } catch (Exception e) {
                throw new SignForceStampException('Stamp callout failed: ' + e.getMessage());
            }
            if (res.getStatusCode() != 200) {
                String rb = res.getBody();
                throw new SignForceStampException('Stamping returned HTTP ' + res.getStatusCode()
                    + ': ' + (rb != null ? rb.substring(0, Math.min(300, rb.length())) : 'null'));
            }
            Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            String stampedBase64 = (String) result.get('pdfBase64');
            if (String.isBlank(stampedBase64)) {
                throw new SignForceStampException('Stamp response contained no pdfBase64');
            }
            stampedPdfBlob = EncodingUtil.base64Decode(stampedBase64);
        }

        // Publish a new file — see the note in stampOriginalToS3: the Site Guest
        // User can neither delete nor version someone else's ContentDocument, and
        // versioning fails silently, which would drop every signature after the
        // first.
        Id stampedCvId = null;
        ContentVersion stampedCv = new ContentVersion();
        stampedCv.Title = stampedFileTitle(agreementId, agr.Name);
        stampedCv.PathOnClient = stampedFileName(agr.Name);
        stampedCv.VersionData = stampedPdfBlob;
        stampedCv.FirstPublishLocationId = agreementId;
        Database.SaveResult sr = Database.insert(stampedCv, true, AccessLevel.SYSTEM_MODE);
        if (sr.isSuccess()) {
            stampedCvId = sr.getId();
        } else {
            System.debug(LoggingLevel.WARN, 'stampOriginalToSalesforce: Stamped CV insert errors: ' + sr.getErrors());
        }

        // Replace any prior Stamped rows (ignore already-deleted).
        List<Agreement_Document__c> oldStamped = [
            SELECT Id FROM Agreement_Document__c
            WHERE Agreement__c = :agreementId AND Document_Type__c = 'Stamped'
        ];
        if (!oldStamped.isEmpty()) {
            try {
                // CRUD: guest/async stamping - skip when the context cannot delete.
                if (Schema.sObjectType.Agreement_Document__c.isDeletable()) {
                    Database.delete(oldStamped, false);
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'stampOriginalToSalesforce: oldStamped delete swallowed: ' + e.getMessage());
            }
        }

        Agreement_Document__c stamped = new Agreement_Document__c();
        stamped.Agreement__c        = agreementId;
        stamped.Name                = (agr.Name + ' - Stamped Signed Document').abbreviate(80);
        stamped.Document_Type__c    = 'Stamped';
        stamped.Content_Version_ID__c = stampedCvId;
        stamped.Storage_Tier__c     = 'Tier1';
        stamped.Storage_Type__c     = 'Salesforce';
        Database.insert(stamped, true, AccessLevel.SYSTEM_MODE);

        System.debug('stampOriginalToSalesforce: ✅ Stamped stored in Salesforce, CV=' + stampedCvId);
    }

    /**
     * DOCX/DOC original → PDF base64 for the stamper, via the backend:
     * convertToPdf (LibreOffice, uploads to S3) then proxyUrl to pull the bytes
     * back server-side. Runs in the async stamping context, so the extra two
     * callouts are safe.
     */
    private static String convertOriginalToPdfBase64(ContentVersion cv) {
        String endpoint = SignForceConfigServiceGuest.getLambdaEndpoint();
        String fileName = String.isNotBlank(cv.PathOnClient)
            ? cv.PathOnClient
            : (String.isNotBlank(cv.Title) ? cv.Title : 'document.docx');

        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(120000);
        req.setBody(JSON.serialize(new Map<String, Object>{
            'action'   => 'convertToPdf',
            'orgId'    => UserInfo.getOrganizationId(),
            'docId'    => 'agrstamp_' + cv.Id + '_' + String.valueOf(System.currentTimeMillis()),
            'base64'   => EncodingUtil.base64Encode(cv.VersionData),
            'filename' => fileName
        }));
        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            throw new SignForceStampException(
                'Original DOCX→PDF conversion failed: HTTP ' + res.getStatusCode());
        }
        Map<String, Object> conv = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        String url = (String) conv.get('url');
        if (conv.get('success') != true || String.isBlank(url)) {
            throw new SignForceStampException(
                'Original DOCX→PDF conversion failed: ' + conv.get('error'));
        }

        HttpRequest proxy = new HttpRequest();
        proxy.setEndpoint(endpoint);
        proxy.setMethod('POST');
        proxy.setHeader('Content-Type', 'application/json');
        proxy.setTimeout(120000);
        proxy.setBody(JSON.serialize(new Map<String, String>{ 'proxyUrl' => url }));
        res = new Http().send(proxy);
        if (res.getStatusCode() != 200) {
            throw new SignForceStampException(
                'Converted PDF fetch failed: HTTP ' + res.getStatusCode());
        }
        Map<String, Object> fetched = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        String b64 = (String) fetched.get('pdfBase64');
        if (String.isBlank(b64)) {
            throw new SignForceStampException('Converted PDF fetch returned no bytes');
        }
        return b64;
    }

    /**
     * Tier2/Tier3 stamping path: Original already in S3.
     *
     * Like stampOriginalToS3, this also fetches the stamped PDF bytes and
     * saves them to a ContentVersion BEFORE any DML — so the email step
     * can retrieve them via CV path without callouts. Only caches CV if
     * file is under 6MB (Salesforce CV practical limit).
     */
  /**
   * Stamp a Cloud-tier (>4MB) Original. The Lambda downloads the original from
   * the cloud provider, stamps it, and uploads the stamped PDF straight back to
   * the agreement's Stamped folder — S3 and Salesforce heap are never touched.
   * We store only the returned cloud handle; the completion email fetches the
   * stamped bytes from the cloud on demand.
   */
  private static void stampViaCloud(
        Id agreementId,
        Agreement__c agr,
        Agreement_Document__c origDoc,
        List<Map<String, Object>> fieldList,
        Map<String, Object> meta
    ) {
        // Resolve the destination Stamped folder + provider from the Agreement.
        Agreement__c a = [
            SELECT Cloud_Provider__c, Cloud_Stamped_Folder_Id__c
            FROM Agreement__c WHERE Id = :agreementId LIMIT 1
        ];
        String provider = String.isNotBlank(origDoc.Cloud_Provider__c)
            ? origDoc.Cloud_Provider__c : a.Cloud_Provider__c;
        String stampedFolderId = a.Cloud_Stamped_Folder_Id__c;
        if (String.isBlank(stampedFolderId)) {
            throw new SignForceStampException('stampViaCloud: Stamped folder id missing on agreement');
        }
        String outName = stampedFileName(agr.Name);

        Map<String, Object> payload = new Map<String, Object>{
            'action'       => 'stampCloud',
            'provider'     => provider,
            'orgId'        => UserInfo.getOrganizationId(),
            'sourceFileId' => origDoc.Cloud_File_Id__c,
            'folderId'     => stampedFolderId,
            'fileName'     => outName,
            'fields'       => fieldList,
            'meta'         => meta
        };

        HttpRequest req = new HttpRequest();
        req.setEndpoint(SignForceConfigServiceGuest.getLambdaEndpoint());
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(120000);
        req.setBody(JSON.serialize(payload));

        HttpResponse res;
        try {
            res = new Http().send(req);
        } catch (Exception e) {
            throw new SignForceStampException('stampViaCloud callout failed: ' + e.getMessage());
        }
        if (res.getStatusCode() != 200) {
            String b = res.getBody();
            throw new SignForceStampException('stampViaCloud HTTP ' + res.getStatusCode()
                + ': ' + (b != null ? b.substring(0, Math.min(300, b.length())) : 'null'));
        }
        Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        if (result.get('success') != true) {
            throw new SignForceStampException('stampViaCloud failed: ' + result.get('message'));
        }
        String stampedFileId = (String) result.get('fileId');
        String previewUrl = (String) result.get('previewUrl');
        // Persist the size so the completion email can decide attach-vs-link
        // without having to pull the bytes back just to measure them.
        Decimal stampedSize = result.get('size') != null
            ? (Decimal) Double.valueOf(String.valueOf(result.get('size')))
            : null;
        System.debug('stampViaCloud: ✅ stamped fileId=' + stampedFileId);

        // Remove any prior Stamped rows (idempotent re-stamp), then record the new one.
        List<Agreement_Document__c> oldStamped = [
            SELECT Id FROM Agreement_Document__c
            WHERE Agreement__c = :agreementId AND Document_Type__c = 'Stamped'
        ];
        if (!oldStamped.isEmpty()) {
            try {
                // CRUD: guest/async stamping - skip when the context cannot delete.
                if (Schema.sObjectType.Agreement_Document__c.isDeletable()) {
                    Database.delete(oldStamped, false);
                }
            } catch (Exception delEx) {
                System.debug(LoggingLevel.WARN, 'stampViaCloud: oldStamped delete swallowed: ' + delEx.getMessage());
            }
        }

        Agreement_Document__c stamped = new Agreement_Document__c();
        stamped.Agreement__c = agreementId;
        stamped.Name = (agr.Name + ' - Stamped Signed Document').abbreviate(80);
        stamped.Document_Type__c = 'Stamped';
        stamped.Storage_Type__c = 'Cloud';
        stamped.Cloud_Provider__c = provider;
        stamped.Cloud_File_Id__c = stampedFileId;
        stamped.Cloud_Folder_Id__c = stampedFolderId;
        stamped.S3_Preview_URL__c = previewUrl;
        stamped.File_Size_Bytes__c = stampedSize;
        stamped.Storage_Tier__c = origDoc.Storage_Tier__c != null ? origDoc.Storage_Tier__c : 'Tier2';
        Database.insert(stamped, true, AccessLevel.SYSTEM_MODE);
        System.debug('stampViaCloud: ✅ Stamped record created Id=' + stamped.Id + ', size=' + stampedSize);
    }

  /**
   * File name for the stamped PDF.
   *
   * This lands on ContentVersion.PathOnClient, and IntegrationService reads
   * PathOnClient to name the copy it pushes to Google Drive or OneDrive — so
   * whatever this returns is what the customer sees in their drive.
   *
   * It used to strip everything outside [a-zA-Z0-9._-], which turned
   * "Test - Burlington Textiles Corp of America (12) - Stamped.pdf" into
   * "Test_-_Burlington_Textiles_Corp_of_America__12__-_Stamped.pdf". Spaces and
   * brackets are legal in file names on every platform and in both cloud
   * providers; only the reserved set below is not. That reserved set is the
   * same one IntegrationService.cloudFolderName already uses for folders, so
   * the file and the folder holding it are now named by one rule.
   */
  private static String stampedFileName(String agreementName) {
      String base = String.isBlank(agreementName) ? 'Agreement' : agreementName;
      String cleaned = (base + ' - Stamped.pdf')
          .replaceAll('["*:<>?/\\\\|]', '-')   // reserved on Windows and in Drive
          .replaceAll('\\s+', ' ')             // collapse runs of whitespace
          .trim();
      return String.isBlank(cleaned) ? 'Agreement - Stamped.pdf' : cleaned;
  }

  /**
   * Names a stamped file after the progress it captures.
   *
   * The document is re-stamped after every signature and each stamp is published
   * as its own file — signing runs as the Site Guest User, which the platform lets
   * neither delete nor version the earlier ones. Giving them all the same name left
   * a pile of identical rows with no way to tell which was current, or whose
   * signature each carried.
   *
   * So they are named instead: "Signed 2 of 3 - Darsh Desai" while the round is in
   * progress, and "Final Signed Document" once everyone has signed. Nothing looks
   * files up by title — the Stamped/Signed pointers on Agreement_Document__c are
   * what code resolves through — so this is presentation only.
   */
  private static String stampedFileTitle(Id agreementId, String agreementName) {
      String base = String.isBlank(agreementName) ? 'Agreement' : agreementName;
      try {
          List<Signer__c> signers = [
              SELECT Name, Email__c, Status__c
              FROM Signer__c
              WHERE Agreement__c = :agreementId
              AND (Role__c = 'Signer' OR Role__c = null)
              ORDER BY Signed_Date__c ASC NULLS LAST
          ];
          Integer total = signers.size();
          if (total <= 1) return truncateTitle(base + ' - Signed Document');

          Integer signed = 0;
          String latest = null;
          for (Signer__c s : signers) {
              if (s.Status__c != 'Signed') continue;
              signed++;
              String who = String.isNotBlank(s.Name) ? s.Name : s.Email__c;
              if (String.isNotBlank(who)) latest = who;   // ordered by Signed_Date__c
          }

          if (signed >= total) return truncateTitle(base + ' - Final Signed Document');
          String label = base + ' - Signed ' + signed + ' of ' + total;
          if (String.isNotBlank(latest)) label += ' - ' + latest;
          return truncateTitle(label);
      } catch (Exception e) {
          // Naming must never block a stamp.
          return truncateTitle(base + ' - Stamped Signed Document');
      }
  }

  /** ContentVersion.Title caps at 255 characters. */
  private static String truncateTitle(String title) {
      if (String.isBlank(title)) return 'Signed Document';
      return title.length() > 255 ? title.substring(0, 255) : title;
  }

  private static void stampViaS3(
        Id agreementId,
        Agreement__c agr,
        Agreement_Document__c origDoc,
        List<Map<String, Object>> fieldList,
        Map<String, Object> meta
    ) {
        String orgId = UserInfo.getOrganizationId();
        String stampedDocId = origDoc.S3_Document_ID__c + '_stamped_' + Datetime.now().getTime();

        System.debug('stampViaS3: Start, sourceDocId=' + origDoc.S3_Document_ID__c
            + ', targetDocId=' + stampedDocId);

        Map<String, Object> payload = new Map<String, Object>{
            'action' => 'stampS3',
            'orgId' => orgId,
            'sourceDocId' => origDoc.S3_Document_ID__c,
            'targetDocId' => stampedDocId,
            'fields' => fieldList,
            'meta' => meta
        };

        Http http = new Http();
        HttpRequest req = new HttpRequest();
        req.setEndpoint(SignForceConfigServiceGuest.getLambdaEndpoint());
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(120000);
        req.setBody(JSON.serialize(payload));

        HttpResponse res;
        try {
            res = http.send(req);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'stampViaS3: callout exception: ' + e.getMessage());
            throw new SignForceStampException('Stamp callout failed: ' + e.getMessage());
        }

        System.debug('stampViaS3: HTTP status = ' + res.getStatusCode());
        if (res.getStatusCode() != 200) {
            String respBody = res.getBody();
            String snippet = respBody != null ? respBody.substring(0, Math.min(300, respBody.length())) : 'null';
            System.debug(LoggingLevel.ERROR,
                'stampViaS3: Lambda HTTP ' + res.getStatusCode() + ', body=' + snippet);
            throw new SignForceStampException('Stamping returned HTTP ' + res.getStatusCode() + ': ' + snippet);
        }

        Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        String stampedUrl = (String) result.get('url');
        System.debug('stampViaS3: ✅ Stamping successful, URL=' + stampedUrl);

        // Fetch stamped PDF bytes NOW (before DML) for callout-free email access.
        // Only cache if under ~6MB (ContentVersion size limit considerations).
        Blob stampedPdfBlob = null;
        try {
            HttpRequest pdfReq = new HttpRequest();
            pdfReq.setEndpoint(stampedUrl);
            pdfReq.setMethod('GET');
            pdfReq.setTimeout(120000);
            pdfReq.setHeader('Accept', 'application/pdf');
            HttpResponse pdfRes = new Http().send(pdfReq);
            if (pdfRes.getStatusCode() == 200) {
                Blob raw = pdfRes.getBodyAsBlob();
                if (raw.size() < 6 * 1024 * 1024) {
                    stampedPdfBlob = raw;
                    System.debug('stampViaS3: ✅ Fetched stamped PDF bytes: ' + raw.size());
                } else {
                    System.debug('stampViaS3: Stamped PDF too large for CV cache (' 
                        + raw.size() + ' bytes), S3 only');
                }
            } else {
                System.debug(LoggingLevel.WARN, 'stampViaS3: stamped PDF GET HTTP ' + pdfRes.getStatusCode());
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'stampViaS3: stamped PDF fetch exception: ' + e.getMessage());
        }

        Id stampedCvId = null;
        if (stampedPdfBlob != null) {
            try {
                ContentVersion stampedCv = new ContentVersion();
                stampedCv.Title = stampedFileTitle(agreementId, agr.Name);
                stampedCv.PathOnClient = stampedFileName(agr.Name);
                stampedCv.VersionData = stampedPdfBlob;
                // Origin removed — sometimes restricted in Guest context.
                // Database.insert with SYSTEM_MODE to bypass Guest FLS limitations.
                Database.SaveResult sr = Database.insert(stampedCv, true, AccessLevel.SYSTEM_MODE);
                if (sr.isSuccess()) {
                    stampedCvId = sr.getId();
                    System.debug('stampViaS3: ✅ Stamped CV created Id=' + stampedCvId);
                } else {
                    System.debug(LoggingLevel.WARN, 'stampViaS3: Stamped CV insert errors: ' + sr.getErrors());
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'stampViaS3: Stamped CV insert exception: ' + e.getMessage());
            }
        }

        // SignForceFLS.requireDeletable(Agreement_Document__c.SObjectType);
        // ENTITY_IS_DELETED guard: another async path may have already deleted these rows.
        List<Agreement_Document__c> oldStamped = [
            SELECT Id FROM Agreement_Document__c
            WHERE Agreement__c = :agreementId AND Document_Type__c = 'Stamped'
        ];
        if (!oldStamped.isEmpty()) {
            try {
                // CRUD: skip rather than throw. This runs in guest/async stamping,
                // where a missing delete right must not cost a signature - the
                // superseded row simply stays, as it does when the delete fails.
                Database.DeleteResult[] drs = Schema.sObjectType.Agreement_Document__c.isDeletable()
                    ? Database.delete(oldStamped, false)
                    : new List<Database.DeleteResult>();
                for (Database.DeleteResult dr : drs) {
                    if (!dr.isSuccess()) {
                        for (Database.Error err : dr.getErrors()) {
                            if (err.getStatusCode() != StatusCode.ENTITY_IS_DELETED) {
                                System.debug(LoggingLevel.WARN,
                                    'stampViaS3: oldStamped delete non-fatal error: '
                                    + err.getStatusCode() + ' ' + err.getMessage());
                            }
                        }
                    }
                }
            } catch (Exception delEx) {
                System.debug(LoggingLevel.WARN, 'stampViaS3: oldStamped delete swallowed: ' + delEx.getMessage());
            }
        }

        // System-mode path (guest-safe): CRUD gate intentionally skipped here.
        Agreement_Document__c stamped = new Agreement_Document__c();
        stamped.Agreement__c = agreementId;
        stamped.Name = (agr.Name + ' - Stamped Signed Document').abbreviate(80);
        stamped.Document_Type__c = 'Stamped';
        stamped.S3_Document_ID__c = stampedDocId;
        stamped.S3_Preview_URL__c = stampedUrl;
        stamped.Content_Version_ID__c = stampedCvId;  // Same-transaction CV for callout-free retrieval
        stamped.Storage_Tier__c = origDoc.Storage_Tier__c != null ? origDoc.Storage_Tier__c : 'Tier2';
        Database.insert(stamped, true, AccessLevel.SYSTEM_MODE);

        System.debug('stampViaS3: ✅ Stamped record created Id=' + stamped.Id + ', CV=' + stampedCvId);
    }

    /**
     * Build the field-list payload sent to Lambda's stampS3 action.
    /**
     * Preserves full signature data — no truncation.
     */
    private static List<Map<String, Object>> buildStampFieldList(List<Signature_Field__c> fields) {
        List<Map<String, Object>> fieldList = new List<Map<String, Object>>();
        for (Signature_Field__c f : fields) {
            if (String.isBlank(f.Field_Value__c)) continue;

            Map<String, Object> fm = new Map<String, Object>();
            fm.put('fieldType', f.Field_Type__c);

            // Preserve signature data fully - no truncation or conversion
            fm.put('value', f.Field_Value__c);

            // BUG-041 FIX: Pehle Lambda ko sirf raw Field_Value__c milta tha,
            // jiska Type signature ka format hai "typed:<Name>:<FontFamily>"
            // (e.g. "typed:John Doe:Dancing Script"). Lambda ko font nahi
            // pata tha so it rendered everything in default Arial — typography
            // mismatch between signing UI (cursive script) and signed PDF (Arial).
            // Ab parsedValue + fontFamily explicitly extract karke bhejte hain,
            // taki Lambda renderer signature ko correct script font me draw kare.
            String rawVal = f.Field_Value__c;
            String parsedValue = rawVal;
            String fontFamily = '';
            if (f.Field_Type__c == 'Signature' || f.Field_Type__c == 'Initial') {
                if (String.isNotBlank(rawVal) && rawVal.startsWith('typed:')) {
                    // Format: "typed:Display Name:Font Family"
                    List<String> parts = rawVal.split(':', 3);
                    if (parts.size() >= 2) parsedValue = parts[1];
                    if (parts.size() >= 3) fontFamily = parts[2];
                }
            }
            // BUG-042 FIX: Checkbox field on Lambda render side was drawing
            // 'X' for the checked state. We now send the expected checkmark
            // glyph explicitly so the Lambda renderer (and any other consumer)
            // doesn't have to guess. We send U+2713 (✓) — universally
            // available + renders well in most PDF fonts. When unchecked,
            // we send an empty ballot box character to maintain visible
            // distinction (Lambda can still skip rendering if it prefers).
            if (f.Field_Type__c == 'Checkbox') {
                Boolean isChecked = (rawVal == 'true');
                parsedValue = isChecked ? '\u2713' : '';
                fm.put('checkboxChecked', isChecked);
                fm.put('checkboxSymbol', isChecked ? '\u2713' : '\u2610');
            }
            fm.put('parsedValue', parsedValue);
            fm.put('fontFamily', fontFamily);

            fm.put('page', f.Page_Number__c != null ? (Integer)f.Page_Number__c - 1 : 0);
            fm.put('x', f.X_Position__c);
            fm.put('y', f.Y_Position__c);
            fm.put('width', f.Width__c);
            fm.put('height', f.Height__c);
            fm.put('pageWidth', f.Page_Width__c);
            fm.put('isCompleted', f.Is_Completed__c);

            fm.put('signerName', f.Assigned_Signer__r != null ? f.Assigned_Signer__r.Name : '');
            // Real signing certificate ID for the stamp footer ("CertID · Name ·
            // Date"). Without this the Lambda fell back to using the signer's
            // NAME as the cert ID, so the name printed twice (uppercase cert
            // slot + normal name). Sending the real ID fixes that duplication.
            fm.put('certId', f.Assigned_Signer__r != null ? f.Assigned_Signer__r.Signature_Certificate_ID__c : '');
            fm.put('signerEmail', f.Assigned_Signer__r != null ? f.Assigned_Signer__r.Email__c : '');
            fm.put('signerIp', f.Assigned_Signer__r != null ? f.Assigned_Signer__r.Signing_IP_Address__c : '');
            fm.put('signedTimestamp', f.Assigned_Signer__r != null && f.Assigned_Signer__r.Signed_Date__c != null
                ? f.Assigned_Signer__r.Signed_Date__c.formatGmt('yyyy-MM-dd HH:mm:ss') + ' UTC' : '');

            fieldList.add(fm);
        }
        return fieldList;
    }
}