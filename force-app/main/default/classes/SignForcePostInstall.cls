/**
 * SignForcePostInstall — package Post-Install Script (InstallHandler).
 *
 * Runs automatically after the managed package is installed or upgraded in a
 * subscriber org. It does the parts of setup that CAN be automated:
 *
 *   1. Seeds the SignForce_Admin_Config__c custom setting (org-default record)
 *      so the admin screen has a record to edit.
 *   2. On a FRESH install, grants the "SignForce User" permission set to the
 *      installing admin so the app is usable immediately.
 *
 * It deliberately does NOT try to create/activate an Experience site or its
 * guest user — the platform doesn't allow a package to do that; those remain
 * one-time manual admin steps (see POST_DEPLOYMENT_GUIDE.md).
 *
 * Register this class as the package's Post-Install Script when creating the
 * package version (e.g. `sf package version create --post-install-script ...`
 * or via the packaging UI).
 *
 * Note on DML: custom-setting DML (non-setup) and PermissionSetAssignment DML
 * (setup) cannot run in the same transaction (MIXED_DML), so the permission-set
 * assignment is done in a @future method.
 */
global with sharing class SignForcePostInstall implements InstallHandler {

    global void onInstall(InstallContext context) {
        try {
            seedConfig();
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'SignForcePostInstall.seedConfig: ' + e.getMessage());
        }

        // Only on a fresh install — don't re-grant on every upgrade.
        if (context != null && !context.isUpgrade() && context.installerId() != null) {
            try {
                assignInstallerAsync(context.installerId());
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR, 'SignForcePostInstall.assign: ' + e.getMessage());
            }
        }
    }

    /** Inserts the org-default custom setting record if it doesn't exist yet. */
    @TestVisible
    private static void seedConfig() {
        List<SignForce_Admin_Config__c> existing = [
            SELECT Id FROM SignForce_Admin_Config__c
            WHERE SetupOwnerId = :UserInfo.getOrganizationId() WITH USER_MODE LIMIT 1
        ];
        if (existing.isEmpty()) {
            insert new SignForce_Admin_Config__c(
                SetupOwnerId = UserInfo.getOrganizationId(),
                Default_Storage_Tier__c = 'Tier1'
            );
        }
    }

    /** Setup-object DML in its own transaction to avoid MIXED_DML. */
    @future
    global static void assignInstallerAsync(Id installerId) {
        assignInstaller(installerId);
    }

    @TestVisible
    private static void assignInstaller(Id installerId) {
        if (installerId == null) return;
        try {
            // PermissionSet.Name (DeveloperName) is ALWAYS bare ('SignForce_User')
            // — even in a subscriber org the namespace lives in NamespacePrefix,
            // not in Name. Filter on NamespacePrefix to target THIS package's perm
            // set and never a subscriber's own same-named one.
            String ns = packageNs();
            List<PermissionSet> ps = [
                SELECT Id FROM PermissionSet
                WHERE Name = 'SignForce_User' AND NamespacePrefix = :ns WITH USER_MODE LIMIT 1
            ];
            if (ps.isEmpty()) {
                System.debug(LoggingLevel.ERROR,
                    'SignForcePostInstall: SignForce_User permission set not found (ns=' + ns
                    + '). Installer ' + installerId + ' was NOT auto-granted — assign it manually.');
                return;
            }

            Integer already = [
                SELECT COUNT() FROM PermissionSetAssignment
                WHERE AssigneeId = :installerId AND PermissionSetId = :ps[0].Id
                WITH USER_MODE
            ];
            if (already > 0) return;

            Database.SaveResult sr = Database.insert(
                new PermissionSetAssignment(AssigneeId = installerId, PermissionSetId = ps[0].Id),
                false
            );
            if (!sr.isSuccess()) {
                for (Database.Error err : sr.getErrors()) {
                    System.debug(LoggingLevel.ERROR,
                        'SignForcePostInstall: failed to grant SignForce_User to ' + installerId
                        + ' — ' + err.getStatusCode() + ': ' + err.getMessage());
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'SignForcePostInstall.assignInstaller error: ' + e.getMessage());
        }
    }

    /** This package's bare namespace ('NSIQ_SignForce'), or null when unmanaged. */
    @TestVisible
    private static String packageNs() {
        try {
            return [
                SELECT NamespacePrefix FROM ApexClass
                WHERE Name = 'SignForcePostInstall' WITH USER_MODE LIMIT 1
            ].NamespacePrefix;
        } catch (Exception e) {
            return null;
        }
    }
}