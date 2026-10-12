/**
 * Guard test: the site guest user must not be able to reach the INTERNAL controllers.
 *
 * HISTORY. This class used to call 34 "internal" methods of GuestSigningApi as a guest and assert
 * each refused with the guard message (via a GuestSigningApi.userTypeOverride seam). Those methods
 * no longer live in GuestSigningApi - they are in AgreementController, SalesforceChunkUpload and
 * SignForceBulkSend - and the override seam was removed, so that test could not compile. The thing it
 * protected is now protected by construction: GuestSigningApi has no internal methods to call.
 *
 * WHAT STILL NEEDS GUARDING. An @AuraEnabled method on an internal class is callable by anyone whose
 * profile / permission sets grant access to that CLASS. This test asserts that no permission set a
 * guest user holds grants Apex class access to the internal classes below. If one of them is ever added
 * to the guest permission set (or a new internal controller is, by mistake), this test fails.
 *
 * Both checks read org setup data and pass vacuously when the org has no guest permission set / user
 * (same convention as the old test, which skipped when no guest user existed).
 *
 * Adding an internal controller with @AuraEnabled methods? Add its name to INTERNAL_CLASSES.
 */
@IsTest
private class GuestSigningApiInternalGuardTest {

    private static final String GUEST_PERMSET = 'SignForce_Guest_User_Access';

    private static final List<String> INTERNAL_CLASSES = new List<String>{
        'AgreementController',
        'SalesforceChunkUpload',
        'SignForceBulkSend',
        'SignForceBulkGenerate',
        'DocumentEditorController',
        'SignForceAdminConfigController',
        'DocumentHistoryController',
        'CommentController',
        'DashboardController',
        'TemplateService'
    };

    /** Names of INTERNAL_CLASSES that the given permission sets grant. */
    private static List<String> grantedInternal(Set<Id> permissionSetIds) {
        Map<Id, ApexClass> internal = new Map<Id, ApexClass>(
            [SELECT Id, Name FROM ApexClass WHERE Name IN :INTERNAL_CLASSES]
        );
        List<String> granted = new List<String>();
        if (internal.isEmpty() || permissionSetIds.isEmpty()) {
            return granted;
        }
        for (SetupEntityAccess sea : [
            SELECT SetupEntityId FROM SetupEntityAccess
            WHERE SetupEntityType = 'ApexClass'
              AND ParentId IN :permissionSetIds
              AND SetupEntityId IN :internal.keySet()
        ]) {
            granted.add(internal.get(sea.SetupEntityId).Name);
        }
        return granted;
    }

    @IsTest
    static void guestPermissionSetGrantsNoInternalApexClass() {
        List<PermissionSet> ps = [SELECT Id FROM PermissionSet WHERE Name = :GUEST_PERMSET LIMIT 1];
        if (ps.isEmpty()) {
            System.assert(true, GUEST_PERMSET + ' not present in this org');
            return;
        }
        List<String> granted = grantedInternal(new Set<Id>{ ps[0].Id });
        System.assertEquals(0, granted.size(),
            GUEST_PERMSET + ' must not grant access to internal classes, but grants: ' + String.join(granted, ', '));
    }

    @IsTest
    static void everyPermissionSetHeldByAGuestUserGrantsNoInternalApexClass() {
        Set<Id> held = new Set<Id>();
        for (PermissionSetAssignment a : [
            SELECT PermissionSetId FROM PermissionSetAssignment WHERE Assignee.UserType = 'Guest'
        ]) {
            held.add(a.PermissionSetId);
        }
        if (held.isEmpty()) {
            System.assert(true, 'no guest user in this org');
            return;
        }
        List<String> granted = grantedInternal(held);
        System.assertEquals(0, granted.size(),
            'A permission set (or guest profile) held by a guest user grants internal classes: ' + String.join(granted, ', '));
    }

    @IsTest
    static void everyListedInternalClassStillExistsOrIsHarmless() {
        // Documents which of the listed names are real classes in this org; a typo in INTERNAL_CLASSES
        // would otherwise make the two tests above silently check nothing.
        Integer found = [SELECT COUNT() FROM ApexClass WHERE Name IN :INTERNAL_CLASSES];
        System.assert(found >= 3, 'INTERNAL_CLASSES should match real classes; found ' + found);
    }
}
