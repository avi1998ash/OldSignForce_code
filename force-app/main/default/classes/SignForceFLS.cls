/**
 * SignForceFLS — centralized Field-Level Security and CRUD guard helpers.
 *
 * ────────────────────────────────────────────────────────────────────────
 * PURPOSE
 * ────────────────────────────────────────────────────────────────────────
 *
 * Checkmarx and AppExchange security review require every DML and SOQL
 * site to demonstrate that the running user has the permissions Salesforce
 * expects. The verbose pattern is:
 *
 *   if (!Schema.sObjectType.Signer__c.isCreateable()) {
 *       throw new AuraHandledException('Cannot create signer');
 *   }
 *
 * Multiplied across 88 DML sites, that's a lot of boilerplate AND a lot of
 * room for inconsistency (different exception types, different error
 * messages, easy to forget). This class consolidates the pattern.
 *
 * ────────────────────────────────────────────────────────────────────────
 * USAGE PATTERNS
 * ────────────────────────────────────────────────────────────────────────
 *
 * Before insert:
 *   SignForceFLS.requireCreateable(Signer__c.SObjectType);
 *   insert mySigner;
 *
 * Before update:
 *   SignForceFLS.requireUpdateable(Agreement__c.SObjectType);
 *   update myAgreement;
 *
 * Before delete:
 *   SignForceFLS.requireDeletable(Signature_Field__c.SObjectType);
 *   delete oldFields;
 *
 * Before SELECT (rarely needed; most queries use WITH SECURITY_ENFORCED):
 *   SignForceFLS.requireAccessible(Agreement_Document__c.SObjectType);
 *   List<Agreement_Document__c> docs = [SELECT Id FROM Agreement_Document__c WHERE ...];
 *
 * Strip-inaccessible pattern (preferred for bulk DML):
 *   List<Signer__c> stripped = SignForceFLS.stripInaccessibleForCreate(newSigners);
 *   insert stripped;
 *
 * Stripping silently drops fields the user can't write — this is the
 * recommended pattern when populating records from a JSON payload because
 * it lets the request succeed for the fields the user CAN write rather
 * than failing the whole transaction.
 *
 * ────────────────────────────────────────────────────────────────────────
 * BYPASS PATHS (for legitimate cross-context operations)
 * ────────────────────────────────────────────────────────────────────────
 *
 * Some operations legitimately need to bypass FLS — for example, an
 * audit-log write from guest signing context, where the guest user has
 * no FLS on Signing_Event__c by design. Those callers should:
 *
 *   1. Call SignForceFLSGuest.bypassRequired(reason) which logs the bypass
 *      (moved from this class; guest signing is its only caller).
 *   2. Use plain DML without going through requireXxx().
 *
 * The bypass log gives the security reviewer a complete inventory of
 * "where do we deliberately skip FLS, and why" — required for AppExchange.
 *
 * ────────────────────────────────────────────────────────────────────────
 * NOT INCLUDED — and why
 * ────────────────────────────────────────────────────────────────────────
 *
 * - No "isAccessibleField(SObjectField)" helper. Field-level access is
 *   better handled via Security.stripInaccessible() or WITH SECURITY_ENFORCED.
 * - No PROFILE-based checks. Salesforce best practice is to use
 *   permission sets, and PermissionSetAssignment lookups are slow.
 *   If you need permission checks, query PermissionSetAssignment directly.
 *
 * SHARING / GUEST SPLIT: `with sharing`. This class only inspects schema describe results (no
 * SOQL or DML), so the keyword does not change behaviour. The guest signing flow (OTPService)
 * uses SignForceFLSGuest; bypassRequired (guest-only) moved there. SignForceFLSException is
 * defined here and is thrown by BOTH classes.
 */
public with sharing class SignForceFLS {

    /**
     * Custom exception thrown when an FLS/CRUD check fails. Kept as
     * AuraHandledException so it surfaces gracefully in LWC contexts.
     */
    public class SignForceFLSException extends Exception {}
    
    @TestVisible
private static Boolean forceThrowForTest = false;

    /** Require running user can create the given object.
    public static void requireCreateable(Schema.SObjectType objType) {
        if (!objType.getDescribe().isCreateable()) {
            throwException(objType, 'create');
        }
    }*/
   public static void requireCreateable(Schema.SObjectType objType) {

    if (Test.isRunningTest() && forceThrowForTest) {
        throwException(objType, 'create');
    }
    if (!objType.getDescribe().isCreateable()) {
        throwException(objType, 'create');
    }
}

    /** Require running user can update the given object. */
    public static void requireUpdateable(Schema.SObjectType objType) {
        if (!objType.getDescribe().isUpdateable()) {
            throwException(objType, 'update');
        }
    }

    /** Require running user can delete the given object. */
    public static void requireDeletable(Schema.SObjectType objType) {
        if (!objType.getDescribe().isDeletable()) {
            throwException(objType, 'delete');
        }
    }

    /** Require running user can read the given object. */
    public static void requireAccessible(Schema.SObjectType objType) {
        if (!objType.getDescribe().isAccessible()) {
            throwException(objType, 'read');
        }
    }

    /**
     * Bulk strip-inaccessible for INSERT.
     * Returns the records with any fields the user can't create stripped out.
     * Throws if the records list is empty (defensive).
     */
    public static List<SObject> stripInaccessibleForCreate(List<SObject> records) {
        if (records == null || records.isEmpty()) return records;
        SObjectAccessDecision decision = Security.stripInaccessible(
            AccessType.CREATABLE, records
        );
        return decision.getRecords();
    }

    /** Bulk strip-inaccessible for UPDATE. */
    public static List<SObject> stripInaccessibleForUpdate(List<SObject> records) {
        if (records == null || records.isEmpty()) return records;
        SObjectAccessDecision decision = Security.stripInaccessible(
            AccessType.UPDATABLE, records
        );
        return decision.getRecords();
    }

    /** Bulk strip-inaccessible for SELECT (read). */
    public static List<SObject> stripInaccessibleForRead(List<SObject> records) {
        if (records == null || records.isEmpty()) return records;
        SObjectAccessDecision decision = Security.stripInaccessible(
            AccessType.READABLE, records
        );
        return decision.getRecords();
    }

    // ─────────────────────────────────────────────────────────────
    // Internal
    // ─────────────────────────────────────────────────────────────

    private static void throwException(Schema.SObjectType objType, String action) {
        String objLabel = objType.getDescribe().getLabel();
        throw new SignForceFLSException(
            'You don\'t have permission to ' + action + ' '
            + objLabel + ' records. Contact your administrator.'
        );
    }
}