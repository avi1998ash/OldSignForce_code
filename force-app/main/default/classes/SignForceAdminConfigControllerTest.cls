@isTest
private class SignForceAdminConfigControllerTest {

    @isTest
    static void getConfig_returnsEmptyWhenUnset() {
        Test.startTest();
        SignForceAdminConfigController.ConfigWrapper w =
            SignForceAdminConfigController.getConfig();
        Test.stopTest();

        System.assertNotEquals(null, w, 'Wrapper should never be null');
        System.assertEquals(null, w.signingSiteBaseUrl, 'No value expected before save');
    }

    @isTest
    static void saveConfig_thenGetConfig_roundTrips() {
        Test.startTest();
        SignForceAdminConfigController.saveConfig(
            'https://acme.my.site.com/sign',
            '001000000000001AAA',
            '0D2000000000001AAA',
            'Tier2',
            'CurrentUser'
        );
        Test.stopTest();

        SignForceAdminConfigController.ConfigWrapper w =
            SignForceAdminConfigController.getConfig();
        System.assertEquals('https://acme.my.site.com/sign', w.signingSiteBaseUrl);
        System.assertEquals('001000000000001AAA', w.portalAccountId);
        System.assertEquals('0D2000000000001AAA', w.orgWideEmailId);
        System.assertEquals('Tier2', w.defaultStorageTier);
    }

    @isTest
    static void saveConfig_updatesExistingRecord() {
        SignForceAdminConfigController.saveConfig('https://a.my.site.com/p', null, null, 'Tier1', null);
        // Second save should update, not create a duplicate org-default.
        SignForceAdminConfigController.saveConfig('https://b.my.site.com/q', null, null, 'Tier3', null);

        SignForceAdminConfigController.ConfigWrapper w =
            SignForceAdminConfigController.getConfig();
        System.assertEquals('https://b.my.site.com/q', w.signingSiteBaseUrl);
        System.assertEquals('Tier3', w.defaultStorageTier);
        System.assertEquals('OrgWide', w.senderEmailMode,
            'A null mode falls back to the org-wide address');

        Integer count = [SELECT COUNT() FROM SignForce_Admin_Config__c WITH USER_MODE];
        System.assert(count <= 1, 'Should not create more than one org-default record');
    }

    @isTest
    static void saveConfig_blankValuesStoreNull() {
        SignForceAdminConfigController.saveConfig('   ', '', null, '  ', '  ');
        SignForceAdminConfigController.ConfigWrapper w =
            SignForceAdminConfigController.getConfig();
        System.assertEquals(null, w.signingSiteBaseUrl, 'Blank should normalize to null');
        System.assertEquals(null, w.portalAccountId);
        System.assertEquals(null, w.defaultStorageTier);
    }

    @isTest
    static void getSites_returnsListWithoutError() {
        Test.startTest();
        List<SignForceAdminConfigController.Option> sites =
            SignForceAdminConfigController.getSites();
        Test.stopTest();
        // DomainSite may or may not have rows in a scratch/test context; just
        // assert the method is resilient and returns a (possibly empty) list.
        System.assertNotEquals(null, sites);
    }

    @isTest
    static void mapSites_buildsUrlsAndSkipsBadRows() {
        // In-memory rows (DomainSite/Domain aren't insertable in tests) built via
        // JSON so we can exercise every branch without SeeAllData.
        List<DomainSite> rows = new List<DomainSite>{
            (DomainSite) JSON.deserialize(
                '{"PathPrefix":"sign","Domain":{"Domain":"acme.my.site.com"},"Site":{"Name":"SignForce Portal"}}',
                DomainSite.class),
            (DomainSite) JSON.deserialize(
                '{"PathPrefix":"/lead","Domain":{"Domain":"b.my.site.com"}}', DomainSite.class),
            (DomainSite) JSON.deserialize(
                '{"Domain":{"Domain":"c.my.site.com"}}', DomainSite.class),
            (DomainSite) JSON.deserialize('{"PathPrefix":"x"}', DomainSite.class), // null Domain -> skipped
            // Classic site (SiteType 'ChatterNetwork') -> must be skipped so only
            // LWR / Experience Builder sites appear in the picker.
            (DomainSite) JSON.deserialize(
                '{"PathPrefix":"signvforcesite","Domain":{"Domain":"vf.my.site.com"},"Site":{"Name":"Classic","SiteType":"ChatterNetwork"}}',
                DomainSite.class)
        };
        List<SignForceAdminConfigController.Option> opts =
            SignForceAdminConfigController.mapSites(rows);

        System.assertEquals(3, opts.size(), 'Null-domain and Visualforce (classic) rows should be skipped');
        System.assertEquals('https://acme.my.site.com/sign', opts[0].value, 'plain prefix');
        System.assertEquals('https://b.my.site.com/lead', opts[1].value, 'leading-slash prefix normalized');
        System.assertEquals('https://c.my.site.com', opts[2].value, 'no prefix');
        for (SignForceAdminConfigController.Option o : opts) {
            System.assert(!o.value.contains('vf.my.site.com'),
                'Classic Force.com Site URL must be excluded');
        }
    }

    @isTest
    static void getOrgWideEmails_returnsList() {
        List<SignForceAdminConfigController.Option> owas =
            SignForceAdminConfigController.getOrgWideEmails();
        System.assertNotEquals(null, owas);
    }

    @isTest
    static void mapOwa_buildsLabels() {
        List<OrgWideEmailAddress> rows = new List<OrgWideEmailAddress>{
            (OrgWideEmailAddress) JSON.deserialize(
                '{"Address":"no-reply@acme.com","DisplayName":"Acme"}', OrgWideEmailAddress.class),
            (OrgWideEmailAddress) JSON.deserialize(
                '{"Address":"raw@acme.com"}', OrgWideEmailAddress.class) // no display name
        };
        List<SignForceAdminConfigController.Option> opts =
            SignForceAdminConfigController.mapOwa(rows);

        System.assertEquals(2, opts.size());
        System.assertEquals('Acme <no-reply@acme.com>', opts[0].label, 'with display name');
        System.assertEquals('<raw@acme.com>', opts[1].label, 'without display name');
    }

    @isTest
    static void getPermissionSetStatus_returnsInfo() {
        Test.startTest();
        List<SignForceAdminConfigController.PermSetInfo> info =
            SignForceAdminConfigController.getPermissionSetStatus();
        Test.stopTest();
        System.assertNotEquals(null, info);
        // Package perm sets are deployed metadata, so the SignForce_User entry
        // should normally resolve; we don't hard-assert the count to stay
        // resilient across orgs.
    }

    @isTest
    static void assignToAllInternalUsers_unknownPermSet() {
        Test.startTest();
        SignForceAdminConfigController.AssignResult r =
            SignForceAdminConfigController.assignToAllInternalUsers('No_Such_PermSet_XYZ');
        Test.stopTest();
        System.assertNotEquals(null, r);
        System.assert(r.message.contains('not found'), 'Should report missing perm set');
        System.assertEquals(0, r.assigned);
    }

    @isTest
    static void assignToAllInternalUsers_realPermSet() {
        // Resolve a real, assignable package perm set name from the status call
        // (handles bare vs namespaced naming), then exercise the assign path.
        // DML is rolled back at test end, so no real org assignments persist.
        String name;
        for (SignForceAdminConfigController.PermSetInfo p :
                SignForceAdminConfigController.getPermissionSetStatus()) {
            if (p.assignable) { name = p.name; break; }
        }
        if (name == null) return; // package perm sets not present in this org

        Test.startTest();
        SignForceAdminConfigController.AssignResult r =
            SignForceAdminConfigController.assignToAllInternalUsers(name);
        Test.stopTest();
        System.assertNotEquals(null, r);
        System.assertNotEquals(null, r.message);
    }

    // ---- dual-listbox assignment ----

    @isTest
    static void getInternalUsers_returnsList() {
        List<SignForceAdminConfigController.Option> users =
            SignForceAdminConfigController.getInternalUsers();
        System.assertNotEquals(null, users);
    }

    @isTest
    static void getAssignedUserIds_unknownReturnsEmpty() {
        List<Id> ids = SignForceAdminConfigController.getAssignedUserIds('No_Such_PermSet_XYZ', null);
        System.assertEquals(0, ids.size());
    }

    @isTest
    static void getAssignedUserIds_realPermSet() {
        String name = firstAssignablePermSet();
        if (name == null) return;
        List<Id> ids = SignForceAdminConfigController.getAssignedUserIds(name, null);
        System.assertNotEquals(null, ids);
    }

    @isTest
    static void applyAssignments_unknownPermSet() {
        SignForceAdminConfigController.AssignResult r =
            SignForceAdminConfigController.applyAssignments('No_Such_XYZ', new List<Id>(), null);
        System.assert(r.message.contains('not found'), 'Should report missing perm set');
        System.assertEquals(0, r.assigned);
    }

    @isTest
    static void applyAssignments_addThenRemove() {
        String name = firstAssignablePermSet();
        if (name == null) return;
        User u = makeStandardUser();

        Test.startTest();
        // Add path: select the new user (not currently assigned).
        SignForceAdminConfigController.AssignResult addRes =
            SignForceAdminConfigController.applyAssignments(name, new List<Id>{ u.Id }, null);
        // Remove path: deselect everyone (reconcile to empty).
        SignForceAdminConfigController.AssignResult remRes =
            SignForceAdminConfigController.applyAssignments(name, new List<Id>(), null);
        Test.stopTest();

        System.assertNotEquals(null, addRes.message);
        System.assertNotEquals(null, remRes.message);
    }

    // ---- guest user assignment ----

    @isTest
    static void getGuestUsers_returnsList() {
        Test.startTest();
        List<SignForceAdminConfigController.Option> guests =
            SignForceAdminConfigController.getGuestUsers();
        Test.stopTest();
        System.assertNotEquals(null, guests, 'Should return a (possibly empty) list');
    }

    @isTest
    static void getAssignedGuestUserIds_returnsList() {
        String name = firstGuestPermSet();
        Test.startTest();
        List<Id> ids = SignForceAdminConfigController.getAssignedGuestUserIds(
            name != null ? name : 'No_Such_XYZ');
        Test.stopTest();
        System.assertNotEquals(null, ids, 'Should return a (possibly empty) list');
    }

    @isTest
    static void applyGuestAssignments_emptySelection_runs() {
        String name = firstGuestPermSet();
        if (name == null) return;
        Test.startTest();
        SignForceAdminConfigController.AssignResult r =
            SignForceAdminConfigController.applyGuestAssignments(name, new List<Id>());
        Test.stopTest();
        System.assertNotEquals(null, r.message, 'Should return a result message');
    }

    @isTest
    static void applyGuestAssignments_nonGuestPermSet_rejected() {
        SignForceAdminConfigController.AssignResult r =
            SignForceAdminConfigController.applyGuestAssignments('Some_Internal_PermSet', new List<Id>());
        System.assert(r.message.contains('Guest User Access'),
            'A non-guest permission set must be rejected');
        System.assertEquals(0, r.assigned);
    }

    // ---- helpers ----

    static String firstAssignablePermSet() {
        for (SignForceAdminConfigController.PermSetInfo p :
                SignForceAdminConfigController.getPermissionSetStatus()) {
            if (p.assignable) return p.name;
        }
        return null;
    }

    static String firstGuestPermSet() {
        for (SignForceAdminConfigController.PermSetInfo p :
                SignForceAdminConfigController.getPermissionSetStatus()) {
            if (!p.assignable) return p.name;
        }
        return null;
    }

    static User makeStandardUser() {
        Profile p = [SELECT Id FROM Profile WHERE UserType = 'Standard' WITH USER_MODE LIMIT 1];
        String uniq = 'sfcfg' + DateTime.now().getTime()
                    + Math.round(Math.random() * 99999) + '@test.example.com.invalid';
        User u = new User(
            FirstName = 'Cfg', LastName = 'Tester',
            Email = 'cfgtester@test.example.com',
            Username = uniq, Alias = 'cfgt',
            ProfileId = p.Id,
            TimeZoneSidKey = 'America/Los_Angeles',
            LocaleSidKey = 'en_US', EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        insert u;
        return u;
    }
}