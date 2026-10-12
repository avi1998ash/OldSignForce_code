/**
 * SignForceSessionService — strict single-tab session binding for the guest
 * signing portal (no OTP).
 *
 * GOAL
 * ----
 * A signing link (?token=...) must work in exactly ONE browser tab — the tab
 * that first opened it. If the link is forwarded and opened in any other tab,
 * window, browser, or device, that other context is rejected with a
 * "session timed out" message. The original tab keeps working.
 *
 * SHARING: `with sharing` (as declared). NOT usable by a Site Guest User: guests have no read or
 * edit access to Signer__c (verified with UserRecordAccess), so start() would fail at
 * SignForceAuthz.requireSignerForToken and could not write the session fields. The live guest
 * flow does not use this class: GuestSigningApi.startSigningSession / validateSigningSession carry
 * their own without-sharing implementation. The only callers here are the unused
 * AgreementControllerGuest.startSigningSession (line 85) and validateSigningSession (line 94).
 * To make this class work for a guest it would have to be declared `without sharing`.
 *
 * HOW IT WORKS
 * ------------
 *   start(token):
 *     - Generates a random session token, stores ONLY its SHA-256 hash on the
 *       Signer, and returns the raw token to the browser (kept in that browser's
 *       localStorage). If a session is ALREADY bound, this returns null and the
 *       caller is turned away — see the scanner note below for why that is now
 *       safe to enforce.
 *
 *   validate(token, sessionToken):
 *     - Returns true only if the supplied token matches the bound hash. Used on
 *       refresh (localStorage survives a reload) so the signer is not re-gated,
 *       and by SignForceAuthz on every sensitive call.
 *
 * WHY THE BINDING IS CLAIMED ON A CLICK, NOT ON PAGE LOAD
 * -------------------------------------------------------
 * A strict "first opener wins" rule was tried once before against a page-load
 * binding and had to be relaxed: email security scanners (Microsoft Defender
 * SafeLinks, Mimecast, Proofpoint) and inbox link previews AUTO-OPEN links to
 * check them, so they consumed the binding before the genuine signer ever
 * clicked, and the real signer saw "session timed out".
 *
 * The LWC now calls start() from the signer's Continue click on the e-sign
 * consent gate — a checkbox and a button press. Scanners fetch and even render
 * pages; they do not give consent. So the binding survives for the person the
 * link was actually sent to, and strict enforcement here no longer locks them
 * out. Do not move this call back to page load.
 *
 * RECOVERY: there is intentionally no time-based timeout and no self-service
 * recovery. If the genuine signer switches device or clears storage, they are
 * locked out and the sender must re-send the link. Issuing a fresh access token
 * (resend) clears Session_Token_Hash__c (see AgreementService) so the new link
 * binds cleanly to whoever consents first.
 *
 * HONEST LIMITATION: because there is no identity proof (no OTP), whoever
 * consents FIRST owns the link — including a forwarded recipient who gets there
 * before the intended signer. This blocks reuse of a forwarded link, not a race
 * to open it first. Email OTP is the answer to that; this is not.
 */
public with sharing class SignForceSessionService {

    public class SessionException extends Exception {}

    /**
     * Claim the link for the calling browser, if nobody holds it yet.
     *
     * Call this ONLY from a genuine signer gesture (the consent gate's Continue
     * click). Calling it on page load re-opens the scanner problem described in
     * the class header.
     *
     * @return raw session token to store client-side, or null if the link is
     *         already bound elsewhere (caller should show the timeout screen).
     */
    public static String start(String token) {
        Signer__c signer = SignForceAuthz.requireSignerForToken(token);

        // Strict: the first browser to consent owns the link. Every later
        // browser, incognito window and device is turned away — that is the
        // whole point of the binding.
        if (String.isNotBlank(signer.Session_Token_Hash__c)) {
            AuditTrailServiceGuest.log(
                signer.Agreement__c, 'Signing Session Blocked', signer.Email__c, null, null
            );
            return null;
        }

        String sessionToken = EncodingUtil.convertToHex(Crypto.generateAesKey(128));

        Signer__c upd = new Signer__c(Id = signer.Id);
        upd.Session_Token_Hash__c = sha256Hex(sessionToken);
        upd.Session_Bound_At__c   = DateTime.now();
        update upd;
        SignForceAuthz.invalidateToken(token);

        AuditTrailServiceGuest.log(
            signer.Agreement__c, 'Signing Session Started', signer.Email__c, null, null
        );
        return sessionToken;
    }

    /**
     * True only if sessionToken matches the bound hash for this signer.
     * Never throws — returns false on any problem so the client can re-gate.
     */
    public static Boolean validate(String token, String sessionToken) {
        if (String.isBlank(sessionToken)) return false;
        try {
            SignForceAuthz.requireVerifiedSignerForToken(token, sessionToken);
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    private static String sha256Hex(String input) {
        Blob h = Crypto.generateDigest('SHA-256', Blob.valueOf(input));
        return EncodingUtil.convertToHex(h);
    }
}