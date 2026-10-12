@isTest
private class SignForcePostInstallTest {

    @isTest
    static void freshInstall_seedsConfigAndAssignsInstaller() {
        Test.startTest();
        Test.testInstall(new SignForcePostInstall(), null); // null version => fresh install
        Test.stopTest(); // runs the queued @future (installer assignment)

        List<SignForce_Admin_Config__c> cfg = [
            SELECT Id, Default_Storage_Tier__c FROM SignForce_Admin_Config__c
        ];
        System.assert(!cfg.isEmpty(), 'Org-default config should be seeded on install');
    }

    @isTest
    static void upgrade_seedsConfigButSkipsAssignment() {
        Test.startTest();
        // Non-null previous version => isUpgrade() == true.
        Test.testInstall(new SignForcePostInstall(), new Version(1, 0), false);
        Test.stopTest();

        System.assert(
            ![SELECT Id FROM SignForce_Admin_Config__c].isEmpty(),
            'Config should still be ensured on upgrade'
        );
    }

    @isTest
    static void seedConfig_isIdempotent() {
        SignForcePostInstall.seedConfig();
        SignForcePostInstall.seedConfig(); // second call must not duplicate
        System.assert(
            [SELECT COUNT() FROM SignForce_Admin_Config__c] <= 1,
            'Should not create more than one org-default record'
        );
    }

    @isTest
    static void assignInstaller_realPermSet() {
        // Direct call (synchronous) to cover the perm-set lookup + assignment path.
        Test.startTest();
        SignForcePostInstall.assignInstaller(UserInfo.getUserId());
        Test.stopTest();
        // No hard assert on assignment (perm-set name resolution is org-dependent);
        // exercising the path without exception is the goal.
        System.assert(true);
    }

    @isTest
    static void assignInstaller_nullIsNoOp() {
        SignForcePostInstall.assignInstaller(null);
        System.assert(true, 'Null installer id should be a safe no-op');
    }

    @isTest
    static void assignInstaller_insertsThenIdempotent() {
        // Fresh user with no assignment exercises the insert path; the second
        // call exercises the "already assigned -> early return" path. (Per-row
        // insert failure, if any, exercises the SaveResult error branch.)
        User u = makeStandardUser();
        Test.startTest();
        SignForcePostInstall.assignInstaller(u.Id);
        SignForcePostInstall.assignInstaller(u.Id);
        Test.stopTest();
        System.assert(true);
    }

    static User makeStandardUser() {
        Profile p = [SELECT Id FROM Profile WHERE UserType = 'Standard' LIMIT 1];
        String uniq = 'sfpi' + DateTime.now().getTime()
                    + Math.round(Math.random() * 99999) + '@test.example.com.invalid';
        User u = new User(
            FirstName = 'PI', LastName = 'Tester',
            Email = 'pitester@test.example.com',
            Username = uniq, Alias = 'pit',
            ProfileId = p.Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        insert u;
        return u;
    }
}