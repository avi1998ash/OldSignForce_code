/**
 * SignForceAuthz — central token authorization for guest-reachable surfaces.
 *
 * SHARING: `with sharing` (as declared). This class does NOT work for a Site Guest User:
 * guests have no sharing access to Signer__c / Agreement__c (verified in the org with
 * UserRecordAccess), so every query below returns no rows for a guest and every call would
 * be denied. The live guest signing path does not call this class - GuestSigningApi carries its
 * own private, without-sharing copy of these checks ("INLINED GUEST AUTHORIZATION").
 * Callers here: PDFProxyRestService.cls:50 (its only client, PDFPreview.page, sends no token,
 * so it returns 401 before reaching this class), SignForceSessionService, and the unused
 * AgreementControllerGuest methods. To use this class for a guest it must first be made
 * `without sharing`, with the checks below as the access control: cryptographic token
 * validation, session binding, token expiry, view count limits, and field ownership checks.
 * 
 * The signing portal runs in a guest user context (Site / Experience Cloud).
 * Salesforce sharing alone does not protect data here — the guest profile
 * must have read access to the relevant objects for the portal to work, which
 * means any `@AuraEnabled` method reachable from that page is reachable by
 * any guest holding any valid token (or none at all).
 *
 * Every guest-facing read/write must therefore prove three things on every call:
 *   1. The token resolves to a real, non-expired, non-revoked Signer__c.
 *   2. The signerId/agreementId/fieldId the client sent matches that signer's
 *      own agreement scope.
 *   3. The action (read fields, write field values) is appropriate for the
 *      signer's current Status__c.
 *
 * SESSION BINDING (added for signing-link security):
 *   Sensitive surfaces (signer load, document content, completion) must ALSO
 *   prove the caller holds the session token bound to the first tab that opened
 *   the link — see requireVerifiedSignerForToken(). This blocks forwarded /
 *   leaked links: any second window/device has no bound session token and is
 *   rejected with SESSION_REQUIRED ("session timed out").
 *
 *   Bootstrap methods that must run BEFORE a session exists (session start,
 *   branding) keep using plain requireSignerForToken().
 *
 * This class is the single place those checks live. Callers should ALWAYS go
 * through `requireSignerForToken` / `requireVerifiedSignerForToken` / etc.
 * instead of doing ad-hoc validation, so we have one chokepoint to audit.
 * NOTE: GuestSigningApi has its own inlined copy of these checks; this class is not on the
 * live guest path (see SHARING above).
 *
 * All methods throw AuraHandledException on denial — the LWC will surface the
 * message to the guest as a generic "Access denied" without leaking which
 * check failed. (See the SAFE_DENY_MESSAGE pattern below.)
 */
public with sharing class SignForceAuthz {

    // Single user-visible denial message. Specific reasons are debug-logged
    // server-side but never sent to the client, to avoid token-probing
    // oracles (e.g. "expired" vs "not found" tells an attacker the token
    // existed at some point).
    @TestVisible
    private static final String SAFE_DENY_MESSAGE = 'Access denied. Your signing link may be invalid, expired, or already used.';

    // Distinct message for a missing/mismatched SESSION (not the token). The LWC
    // keys off this to show the "session timed out" screen, not a dead-end error.
    @TestVisible
    public static final String SESSION_REQUIRED_MESSAGE = 'SESSION_REQUIRED';

    // Cached per-transaction so a single LWC turn making 3-4 calls only hits
    // the SOQL once. Keyed by token string.
    private static Map<String, Signer__c> tokenCache = new Map<String, Signer__c>();

    /**
     * Resolve a token to its Signer__c, or throw. Use this when the caller
     * already knows it needs the signer (e.g. when fetching that signer's
     * own fields).
     *
     * Validates: token format, token exists, not manually expired, not past
     * 48h window, view count under cap, signer not already signed/declined.
     *
     * Does NOT increment view count — that's a separate concern in
     * AgreementService.validateToken when the page first loads. Authz is
     * idempotent.
     */
    public static Signer__c requireSignerForToken(String token) {
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
     * Drop any cached copy of this token's signer. Call after mutating a
     * signer's session fields (see SignForceSessionService.start) so a later
     * verify in the SAME transaction re-queries the fresh row instead of a
     * stale cached one. (In production each guest call is its own transaction,
     * so this mainly matters for multi-step test transactions.)
     */
    public static void invalidateToken(String token) {
        if (String.isNotBlank(token)) {
            tokenCache.remove(token);
        }
    }

    /**
     * Token validity PLUS a valid bound session token. This is the gate for
     * every sensitive guest surface (signer load, document, completion).
     *
     * The session is bound to the first tab that opened the link (see
     * SignForceSessionService). A caller without the matching token — a second
     * window, a forwarded link, another device — fails here with SESSION_REQUIRED
     * so the LWC shows "session timed out". There is no time-based expiry; the
     * binding lives as long as the underlying 48h access token does.
     */
    public static Signer__c requireVerifiedSignerForToken(String token, String sessionToken) {
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
     * requireVerifiedSignerForToken (valid token + bound session), with ONE
     * deliberate difference: it does NOT reject a signer whose Status__c is
     * already 'Signed'.
     *
     * Why: the signing certificate is rendered by
     * GuestSigningApi.generateSigningCertificateSecure, which the
     * viewer calls the instant completeSigning succeeds — and by then
     * markSigned() has already flipped THIS signer to 'Signed'.
     * requireVerifiedSignerForToken denies a 'Signed' signer ("already
     * signed"), so the render for the final signer always failed and the
     * certificate never attached to the completion email. Every other guard
     * (token revoked, 48h window, view cap, bound session) is unchanged, so a
     * leaked/forwarded link still cannot render a certificate.
     */
    public static Signer__c requireVerifiedSignerForCertRender(String token, String sessionToken) {
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
        // NO 'already signed' rejection here — see the doc comment above. The
        // signer IS signed at this point; that is exactly when the certificate
        // must render.
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
     * Like requireSignerForToken, but also asserts the resolved signer's Id
     * matches the signerId the caller supplied. Use this when an LWC method
     * takes both (token, signerId) — without this check the client could
     * send token=mine, signerId=someone-else's.
     */
    public static Signer__c requireSignerForTokenAndId(String token, Id claimedSignerId) {
        Signer__c signer = requireSignerForToken(token);
        if (signer.Id != claimedSignerId) {
            denyWithLog('signerId mismatch: token=' + signer.Id + ' claimed=' + claimedSignerId);
        }
        return signer;
    }

    /**
     * Like requireSignerForToken, but also asserts the resolved signer belongs
     * to the agreementId the caller supplied. Use this when an LWC method
     * takes (token, agreementId) — e.g. fetching the document for signing.
     */
    public static Signer__c requireSignerForTokenAndAgreement(String token, Id claimedAgreementId) {
        Signer__c signer = requireSignerForToken(token);
        if (signer.Agreement__c != claimedAgreementId) {
            denyWithLog('agreementId mismatch: signer=' + signer.Id + ' agr=' + signer.Agreement__c + ' claimed=' + claimedAgreementId);
        }
        return signer;
    }

    /**
     * Verify a list of Signature_Field__c IDs all belong to the agreement
     * the token's signer is on, AND all are assigned to that signer.
     * Use before any bulk field write from a guest.
     *
     * Returns the field-id set so callers can short-circuit bad inputs
     * without re-querying.
     */
    public static Set<Id> requireFieldsBelongToSigner(String token, Set<Id> fieldIds) {
        if (fieldIds == null || fieldIds.isEmpty()) return new Set<Id>();
        Signer__c signer = requireSignerForToken(token);

        // SOQL with the agreement + assignment scope baked in. If any of the
        // claimed IDs aren't in scope they simply won't come back; we then
        // compare counts to detect tampering.
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
     * Used by PDFProxyRestService — verify a ContentVersion ID actually
     * belongs to a document on the agreement the token is for.
     *
     * Without this any guest could request any ContentVersion in the org
     * by guessing the 18-char ID.
     */
    public static void requireContentVersionForToken(String token, Id contentVersionId) {
        Signer__c signer = requireSignerForToken(token);

        // ContentVersion belongs to a ContentDocument, which is linked to
        // the Agreement via ContentDocumentLink. We also accept the
        // Agreement_Document__c.Content_Version_ID__c path (Tier1 storage).
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

    /**
     * Internal: log the real reason server-side, throw the safe message client-side.
     * The debug log is what the security reviewer will look at; the client gets
     * one consistent denial message regardless of which check failed.
     */
    private static void denyWithLog(String reason) {
        System.debug(LoggingLevel.WARN, '[SignForceAuthz] DENY: ' + reason);
        throw new AuraHandledException(SAFE_DENY_MESSAGE);
    }

    /**
     * Session-specific denial: distinct message so the LWC shows "session timed out".
     */
    private static void denySession(String reason) {
        System.debug(LoggingLevel.WARN, '[SignForceAuthz] SESSION DENY: ' + reason);
        throw new AuraHandledException(SESSION_REQUIRED_MESSAGE);
    }

    /**
     * For use from REST endpoints (PDFProxyRestService) where AuraHandledException
     * isn't appropriate — they want to set HTTP status codes themselves.
     */
    public class AuthzException extends Exception {}

    public static Signer__c requireSignerForTokenRest(String token) {
        try {
            return requireSignerForToken(token);
        } catch (AuraHandledException e) {
            throw new AuthzException(SAFE_DENY_MESSAGE);
        }
    }

    public static void requireContentVersionForTokenRest(String token, Id cvId) {
        try {
            requireContentVersionForToken(token, cvId);
        } catch (AuraHandledException e) {
            throw new AuthzException(SAFE_DENY_MESSAGE);
        }
    }
}