/**
 * SignForceFLSGuest - guest-side copy of the SignForceFLS methods the guest signing flow uses
 * (OTPService). Internal callers use SignForceFLS.
 *
 * SHARING: `with sharing`. The methods only inspect schema describe results and write a debug
 * line - they perform no SOQL or DML - so the keyword has no effect on behaviour.
 *
 * EXCEPTION TYPE: failures still throw SignForceFLS.SignForceFLSException (the ORIGINAL type,
 * not a copy), so every existing `catch (SignForceFLS.SignForceFLSException e)` keeps working.
 * That one qualifier is the only difference from the SignForceFLS code this was copied from.
 *
 *   requireAccessible - BOTH: verbatim copy of SignForceFLS.requireAccessible
 *   bypassRequired    - GUEST-ONLY: moved here from SignForceFLS (only OTPService called it)
 *   throwException    - private helper, copied (qualified exception type, see above)
 */
public with sharing class SignForceFLSGuest {

    /** Require running user can read the given object. */
    public static void requireAccessible(Schema.SObjectType objType) {
        if (!objType.getDescribe().isAccessible()) {
            throwException(objType, 'read');
        }
    }

    /**
     * Document a deliberate FLS bypass in the debug log. Use this in any
     * code path that legitimately skips FLS guards (e.g., guest audit
     * writes, async @future processing, system-context operations).
     *
     * The reason is logged so security reviewers can audit every bypass site.
     */
    public static void bypassRequired(String reason) {
        System.debug(LoggingLevel.INFO,
            '[SignForceFLS] FLS bypass declared: ' + reason
            + ' | callerUser=' + UserInfo.getUserId()
            + ' | userType=' + UserInfo.getUserType());
    }

    // -----------------------------------------------------------------
    // Internal
    // -----------------------------------------------------------------

    private static void throwException(Schema.SObjectType objType, String action) {
        String objLabel = objType.getDescribe().getLabel();
        throw new SignForceFLS.SignForceFLSException(
            'You don\'t have permission to ' + action + ' '
            + objLabel + ' records. Contact your administrator.'
        );
    }
}
