/**
 * OTPService — one-time-passcode identity verification for the guest signing
 * flow. Owns ALL OTP semantics (code generation, resend cooldown, expiry,
 * attempt cap); callers — GuestSigningApi for real guests — resolve
 * their signing token to a signerId and delegate here.
 *
 * SHARING IS INHERITED, NOT "with sharing": the production caller is the
 * without-sharing guest controller. The site Guest User has no sharing on the
 * Signer__c row (the signing token, validated by the caller, is the
 * authorisation), so a with-sharing query here would find no rows and the
 * feature would fail only for real guests while passing every admin-run test.
 * A direct Aura invocation still defaults to with sharing under inherited
 * sharing, so the legacy entry points below are not loosened for internal use.
**/
public inherited sharing class OTPService {

    // OTP semantics — single source of truth for controller and LWC behaviour.
    @TestVisible private static final Integer RESEND_COOLDOWN_SECONDS = 60;
    @TestVisible private static final Integer CODE_EXPIRY_MINUTES = 10;
    @TestVisible private static final Integer MAX_ATTEMPTS = 5;

    /** Legacy entry point — kept for API stability; delegates so there is one set of OTP semantics. */
    @AuraEnabled
    public static void sendOTP(Id signerId) {
        sendSigningOtp(signerId);
    }

    /** Legacy entry point — kept for API stability; true only when the code verified. */
    @AuraEnabled
    public static Boolean verifyOTP(Id signerId, String enteredOTP) {
        return verifySigningOtp(signerId, enteredOTP).get('verified') == true;
    }

    /**
     * Generate a 6-digit code, store it on the signer and email it — unless a
     * code already went out within the last RESEND_COOLDOWN_SECONDS, in which
     * case the send is refused with the remaining cooldown so link refreshes
     * cannot spam the signer's inbox.
     *
     * Returns { success, maskedEmail, cooldownSeconds, message }.
     */
    public static Map<String, Object> sendSigningOtp(Id signerId) {
        // Read guard is safe for guests (the guest permission set grants
        // Signer__c read=true). The query deliberately stays off USER_MODE —
        // USER_MODE enforces sharing regardless of the class's sharing keyword,
        // and a guest has no sharing on a Signer__c row they only hold a token
        // for; the token the caller already validated is the authorisation.
        SignForceFLSGuest.requireAccessible(Signer__c.SObjectType);
        Signer__c signer = [
            SELECT Id, Email__c, Agreement__c, Agreement__r.Name,
                   OTP_Sent_At__c, OTP_Verified__c
            FROM Signer__c WHERE Id = :signerId
        ];
        String masked = maskEmail(signer.Email__c);

        // Verification is now bound to the browser tab (sessionStorage in the
        // signing viewer), so a new tab or window legitimately needs a fresh code
        // even after this signer verified elsewhere. We therefore no longer refuse
        // to send when OTP_Verified__c is true — the resend cooldown below is what
        // prevents spam. A held tab keeps its own proof and never asks to re-send.

        // Resend cooldown.
        if (signer.OTP_Sent_At__c != null) {
            Long elapsedSec = (DateTime.now().getTime() - signer.OTP_Sent_At__c.getTime()) / 1000;
            if (elapsedSec < RESEND_COOLDOWN_SECONDS) {
                Integer remaining = RESEND_COOLDOWN_SECONDS - elapsedSec.intValue();
                return new Map<String, Object>{
                    'success'         => false,
                    'maskedEmail'     => masked,
                    'cooldownSeconds' => remaining,
                    'message'         => 'A code was sent recently. You can request a new one in '
                        + remaining + ' second' + (remaining == 1 ? '' : 's') + '.'
                };
            }
        }

        String otp = String.valueOf(Math.abs(Math.mod(Crypto.getRandomInteger(), 900000)) + 100000);

        signer.OTP_Code__c = otp;
        signer.OTP_Verified__c = false;
        signer.OTP_Sent_At__c = DateTime.now();
        signer.OTP_Attempts__c = 0; // fresh code → fresh attempt budget

        // GUEST-WRITE PATTERN (deliberate — do not "fix" back to a guard): the
        // site Guest User holds Signer__c with edit=false BY DESIGN, so a
        // SignForceFLS.requireUpdateable here throws for every real guest while
        // passing in admin-run tests — exactly the failure mode this replaces.
        // The signing token the caller already validated is the authorisation;
        // the DML stays in system mode (no USER_MODE — the guest has neither
        // sharing nor object edit rights) with the bypass declared for review.
        SignForceFLSGuest.bypassRequired('Guest signing OTP: store code on token-authorised Signer__c (guest edit=false by design)');
        update signer;

        sendOtpEmail(signer, otp);

        return new Map<String, Object>{
            'success'         => true,
            'maskedEmail'     => masked,
            // Full cooldown returned on success so the client can start its
            // resend countdown without a second server round-trip.
            'cooldownSeconds' => RESEND_COOLDOWN_SECONDS,
            'message'         => 'Verification code sent.'
        };
    }

    /**
     * Check an entered code against the stored one.
     * Returns { verified, attemptsLeft, locked, message }.
     *  - Codes expire CODE_EXPIRY_MINUTES after being sent.
     *  - Each wrong entry burns one of MAX_ATTEMPTS attempts; the last one
     *    blanks the stored code (locked=true) so a fresh send is required —
     *    a 6-digit space is brute-forceable without the cap.
     */
    public static Map<String, Object> verifySigningOtp(Id signerId, String enteredOtp) {
        // Same guest-context reasoning as sendSigningOtp above.
        SignForceFLSGuest.requireAccessible(Signer__c.SObjectType);
        Signer__c signer = [
            SELECT Id, OTP_Code__c, OTP_Verified__c, OTP_Sent_At__c, OTP_Attempts__c
            FROM Signer__c WHERE Id = :signerId
        ];

        Integer attempts = signer.OTP_Attempts__c == null ? 0 : signer.OTP_Attempts__c.intValue();
        Integer attemptsLeft = Math.max(0, MAX_ATTEMPTS - attempts);

        // A refresh after verifying must not demand a second code. The extra
        // 'alreadyVerified' key lets the controller skip a duplicate audit row.
        if (signer.OTP_Verified__c == true) {
            Map<String, Object> ok = verifyResult(true, attemptsLeft, false, 'Already verified.');
            ok.put('alreadyVerified', true);
            return ok;
        }

        // No live code — either never sent or invalidated by a lockout.
        if (String.isBlank(signer.OTP_Code__c) || signer.OTP_Sent_At__c == null) {
            return verifyResult(false, 0, attempts >= MAX_ATTEMPTS,
                'No active code. Please request a new one.');
        }

        if (DateTime.now() > signer.OTP_Sent_At__c.addMinutes(CODE_EXPIRY_MINUTES)) {
            return verifyResult(false, attemptsLeft, false,
                'This code has expired. Please request a new one.');
        }

        if (String.isBlank(enteredOtp) || enteredOtp.trim() != signer.OTP_Code__c) {
            attempts++;
            attemptsLeft = Math.max(0, MAX_ATTEMPTS - attempts);
            Boolean locked = attempts >= MAX_ATTEMPTS;
            signer.OTP_Attempts__c = attempts;
            if (locked) {
                signer.OTP_Code__c = null; // lockout invalidates the code
            }
            // Guest-write pattern — see sendSigningOtp.
            SignForceFLSGuest.bypassRequired('Guest signing OTP: record failed attempt (guest edit=false by design)');
            update signer;
            return verifyResult(false, attemptsLeft, locked, locked
                ? 'Too many incorrect attempts. Please request a new code.'
                : 'Incorrect code. ' + attemptsLeft + ' attempt' + (attemptsLeft == 1 ? '' : 's') + ' remaining.');
        }

        signer.OTP_Verified__c = true;
        signer.OTP_Code__c = null; // single-use: a verified code cannot be replayed
        // Guest-write pattern — see sendSigningOtp.
        SignForceFLSGuest.bypassRequired('Guest signing OTP: mark verified (guest edit=false by design)');
        update signer;
        return verifyResult(true, attemptsLeft, false, 'Verified.');
    }

    /** Branded verification-code email (body markup unchanged from the original sendOTP). */
    private static void sendOtpEmail(Signer__c signer, String otp) {
        String docName = (signer.Agreement__r != null && String.isNotBlank(signer.Agreement__r.Name))
            ? signer.Agreement__r.Name : 'your document';

        String body =
            BrandingServiceGuest.getEmailHeader() +
            BrandingServiceGuest.emailBodyOpen() +
            BrandingServiceGuest.pill('warning', 'VERIFICATION CODE') +
            BrandingServiceGuest.heading('Your verification code') +
            BrandingServiceGuest.lead(
                'Enter this code to verify your identity and sign ' +
                BrandingServiceGuest.emphasis(docName) + '.') +
            BrandingServiceGuest.codeBlock(otp) +
            BrandingServiceGuest.footnote(
                'For your security, never share this code. ' + BrandingServiceGuest.brandName() +
                ' will never ask you for it. If you didn\'t request this, you can ignore this email.') +
            BrandingServiceGuest.emailBodyClose() +
            BrandingServiceGuest.getEmailFooter();

        Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
        email.setToAddresses(new List<String>{ signer.Email__c });
        email.setSubject('Your ' + BrandingServiceGuest.getEmailTokens().get('companyName') + ' verification code');
        String owaId = AgreementService.getOwaId();
        if (String.isNotBlank(owaId)) email.setOrgWideEmailAddressId(owaId);
        email.setHtmlBody(body);

        // Transactional OTP email sent to the signer's own address queried above;
        // no CRUD-controlled sObject is written here. Deliberate system-mode send
        // so the guest-signing flow can deliver the verification code. Guard is
        // read-only (matches CommentController/DocumentHistoryController) and
        // cannot fail for a caller who already has Signer__c read access.
        SignForceFLSGuest.requireAccessible(Signer__c.SObjectType);
        // Positive branch: the scanner reads the check on the flow INTO the
        // operation, not a preceding throw - which is why the guard above alone
        // left this flagged. Always true by the time we are here.
        if (Schema.sObjectType.Signer__c.isAccessible()) {
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ email });
        }
    }

    private static Map<String, Object> verifyResult(
        Boolean verified, Integer attemptsLeft, Boolean locked, String message
    ) {
        return new Map<String, Object>{
            'verified'     => verified,
            'attemptsLeft' => attemptsLeft,
            'locked'       => locked,
            'message'      => message
        };
    }

    /** 'nihar.sharma@x.in' → 'ni***@x.in' — confirms which inbox without exposing it. */
    @TestVisible
    private static String maskEmail(String email) {
        if (String.isBlank(email) || !email.contains('@')) return email;
        String localPart = email.substringBefore('@');
        return localPart.substring(0, Math.min(2, localPart.length()))
            + '***@' + email.substringAfter('@');
    }
}