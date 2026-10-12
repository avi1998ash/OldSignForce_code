/**
 * SignForceLicenceControllerTest
 *
 * PackageLicense and UserPackageLicense are read-only setup entities: neither can
 * be inserted, even in a test context. So the seat arithmetic is exercised by
 * deserializing a PackageLicense in memory and standing it in through the
 * controller's @TestVisible cache. Everything that does NOT need a licence — the
 * roster, the admin gate, the graceful "no licence in this org" behaviour — runs
 * against the real org state.
 */
@isTest
private class SignForceLicenceControllerTest {

    // ── helpers ──────────────────────────────────────────────────────────

    /** A PackageLicense cannot be constructed field-by-field (its counts are not
     *  writeable), so build one through JSON and inject it. */
    private static void stubLicence(Integer allowed, Integer used, Datetime expires) {
        Map<String, Object> m = new Map<String, Object>{
            'AllowedLicenses' => allowed,
            'UsedLicenses'    => used,
            'Status'          => 'Active',
            'NamespacePrefix' => 'esignforce'
        };
        if (expires != null) m.put('ExpirationDate', expires);
        SignForceLicenceController.cachedPl =
            (PackageLicense) JSON.deserialize(JSON.serialize(m), PackageLicense.class);
        SignForceLicenceController.plLoaded = true;
    }

    /** Forces "this org has no package licence", which is the packaging-org state. */
    private static void stubNoLicence() {
        SignForceLicenceController.cachedPl = null;
        SignForceLicenceController.plLoaded = true;
    }

    private static User standardUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String uniq = String.valueOf(DateTime.now().getTime())
                    + String.valueOf(Math.round(Math.random() * 100000));
        User u = new User(
            FirstName         = 'Lic',
            LastName          = 'User' + uniq,
            Email             = 'lic' + uniq + '@example.com',
            Username          = 'lic' + uniq + '@esignforce.test',
            Alias             = 'licu',
            ProfileId         = p.Id,
            TimeZoneSidKey    = 'America/Los_Angeles',
            LocaleSidKey      = 'en_US',
            EmailEncodingKey  = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        insert u;
        return u;
    }

    // ── the roster ───────────────────────────────────────────────────────

    @isTest
    static void getLicencePage_asAdmin_returnsSummaryAndRoster() {
        Test.startTest();
        SignForceLicenceController.LicencePage page = SignForceLicenceController.getLicencePage();
        Test.stopTest();

        System.assertNotEquals(null, page.summary, 'A summary must always be returned.');
        System.assert(!page.users.isEmpty(), 'The running admin should appear in the roster.');

        Boolean foundSelf = false;
        for (SignForceLicenceController.SeatUser u : page.users) {
            if (u.userId == UserInfo.getUserId()) { foundSelf = true; break; }
        }
        System.assert(foundSelf, 'The roster must include the running user.');

        for (SignForceLicenceController.SeatUser u : page.users) {
            System.assertNotEquals(null, u.state, 'Every row needs a plain-English state.');
            System.assertEquals(u.hasLicence && u.hasPermSet, u.ready,
                'ready must mean licence AND permission set, nothing looser.');
        }
    }

    @isTest
    static void getLicencePage_asNonAdmin_isRefused() {
        User u = standardUser();
        Boolean refused = false;

        Test.startTest();
        System.runAs(u) {
            try {
                SignForceLicenceController.getLicencePage();
            } catch (Exception e) {
                refused = true;
                System.assert(e.getMessage().containsIgnoreCase('administrator')
                           || e.getMessage().containsIgnoreCase('Customize Application'),
                    'The refusal should name the missing permission. Got: ' + e.getMessage());
            }
        }
        Test.stopTest();

        System.assert(refused, 'A non-administrator must not be able to read the seat roster.');
    }

    // ── seat arithmetic ──────────────────────────────────────────────────

    @isTest
    static void summary_countsRemainingAndPercentUsed() {
        stubLicence(10, 7, null);

        Test.startTest();
        SignForceLicenceController.LicencePage page = SignForceLicenceController.getLicencePage();
        Test.stopTest();

        SignForceLicenceController.SeatSummary s = page.summary;
        System.assertEquals(true, s.licenceManaged, 'A stubbed licence means the org is managed.');
        System.assertEquals(false, s.unlimited);
        System.assertEquals(10, s.allowed);
        System.assertEquals(7,  s.used);
        System.assertEquals(3,  s.remaining, '10 purchased minus 7 used is 3 left.');
        System.assertEquals(70, s.percentUsed);
    }

    @isTest
    static void summary_neverReportsNegativeRemaining() {
        // Salesforce can report more used than allowed after a downgrade. The UI
        // must show 0 left, never a negative number.
        stubLicence(5, 8, null);

        Test.startTest();
        SignForceLicenceController.SeatSummary s = SignForceLicenceController.getLicencePage().summary;
        Test.stopTest();

        System.assertEquals(0, s.remaining, 'Over-subscription must floor at zero, not go negative.');
    }

    @isTest
    static void summary_unlimitedSiteLicence() {
        stubLicence(-1, 42, null);

        Test.startTest();
        SignForceLicenceController.SeatSummary s = SignForceLicenceController.getLicencePage().summary;
        Test.stopTest();

        System.assertEquals(true, s.unlimited, '-1 allowed licences means site-wide.');
        System.assertEquals(-1, s.remaining, 'Unlimited is reported as -1, not a count.');
        System.assert(s.note != null && s.note.containsIgnoreCase('site-wide'),
            'The note should explain what unlimited means. Got: ' + s.note);
    }

    @isTest
    static void summary_flagsLicenceExpiringWithin30Days() {
        stubLicence(10, 1, Datetime.now().addDays(10));

        Test.startTest();
        SignForceLicenceController.SeatSummary s = SignForceLicenceController.getLicencePage().summary;
        Test.stopTest();

        System.assertEquals(true, s.expiringSoon, 'Ten days out must be flagged as expiring soon.');
        System.assertNotEquals(null, s.expirationDate);
    }

    @isTest
    static void summary_doesNotFlagDistantExpiry() {
        stubLicence(10, 1, Datetime.now().addDays(120));

        Test.startTest();
        SignForceLicenceController.SeatSummary s = SignForceLicenceController.getLicencePage().summary;
        Test.stopTest();

        System.assertEquals(false, s.expiringSoon, '120 days out is not "expiring soon".');
    }

    @isTest
    static void summary_withNoLicence_isManagedFalseAndExplains() {
        stubNoLicence();

        Test.startTest();
        SignForceLicenceController.SeatSummary s = SignForceLicenceController.getLicencePage().summary;
        Test.stopTest();

        System.assertEquals(false, s.licenceManaged);
        System.assert(String.isNotBlank(s.note), 'The screen must explain why it shows no seats.');
        System.assert(s.note.containsIgnoreCase('no package license'),
            'The note must say plainly that no licence exists. Got: ' + s.note);
    }

    // ── assigning ────────────────────────────────────────────────────────

    @isTest
    static void assignLicences_withNoInput_doesNothing() {
        Test.startTest();
        SignForceLicenceController.SeatResult a = SignForceLicenceController.assignLicences(null);
        SignForceLicenceController.SeatResult b = SignForceLicenceController.assignLicences(new List<Id>());
        Test.stopTest();

        System.assertEquals(0, a.succeeded);
        System.assertEquals(0, b.succeeded);
        System.assertNotEquals(null, a.summary, 'A summary is returned even on a no-op.');
    }

    @isTest
    static void assignLicences_withoutAPackageLicence_explainsWhy() {
        stubNoLicence();
        Boolean threw = false;

        Test.startTest();
        try {
            SignForceLicenceController.assignLicences(new List<Id>{ UserInfo.getUserId() });
        } catch (Exception e) {
            threw = true;
            System.assert(e.getMessage().containsIgnoreCase('no eSignforce package licence'),
                'The error should say the org has no licence to assign. Got: ' + e.getMessage());
        }
        Test.stopTest();

        System.assert(threw, 'Assigning with no package licence must fail loudly, not silently.');
    }

    @isTest
    static void assignLicences_overCapacity_refusesRatherThanPartiallyApplying() {
        // Every seat already taken; asking for one more must be rejected outright
        // so the admin is never left guessing which users actually landed.
        stubLicence(5, 5, null);
        User u = standardUser();
        Boolean threw = false;

        Test.startTest();
        try {
            SignForceLicenceController.assignLicences(new List<Id>{ u.Id });
        } catch (Exception e) {
            threw = true;
            System.assert(e.getMessage().containsIgnoreCase('not enough seats'),
                'The error should name the seat shortage. Got: ' + e.getMessage());
        }
        Test.stopTest();

        System.assert(threw, 'Assigning beyond capacity must be refused.');
    }

    @isTest
    static void assignLicences_asNonAdmin_isRefused() {
        User u = standardUser();
        Boolean refused = false;

        Test.startTest();
        System.runAs(u) {
            try {
                SignForceLicenceController.assignLicences(new List<Id>{ u.Id });
            } catch (Exception e) {
                refused = true;
            }
        }
        Test.stopTest();

        System.assert(refused, 'Only an administrator may hand out seats.');
    }

    // ── revoking ─────────────────────────────────────────────────────────

    @isTest
    static void revokeLicences_withNoInput_doesNothing() {
        Test.startTest();
        SignForceLicenceController.SeatResult a = SignForceLicenceController.revokeLicences(null);
        SignForceLicenceController.SeatResult b = SignForceLicenceController.revokeLicences(new List<Id>());
        Test.stopTest();

        System.assertEquals(0, a.succeeded);
        System.assertEquals(0, b.succeeded);
    }

    @isTest
    static void revokeLicences_withoutAPackageLicence_isGraceful() {
        // Unlike assign, revoking in an unlicensed org is a no-op rather than an
        // error: there is nothing to take away, and failing would be noise.
        stubNoLicence();

        Test.startTest();
        SignForceLicenceController.SeatResult r =
            SignForceLicenceController.revokeLicences(new List<Id>{ UserInfo.getUserId() });
        Test.stopTest();

        System.assertEquals(0, r.succeeded);
        System.assert(r.failures.isEmpty(), 'A no-op revoke should not report failures.');
        System.assertNotEquals(null, r.summary);
    }

    @isTest
    static void revokeLicences_forSomeoneWithoutASeat_reportsNothingRemoved() {
        stubLicence(10, 2, null);
        User u = standardUser();

        Test.startTest();
        SignForceLicenceController.SeatResult r =
            SignForceLicenceController.revokeLicences(new List<Id>{ u.Id });
        Test.stopTest();

        System.assertEquals(0, r.succeeded, 'Nobody held a seat, so nothing is removed.');
        System.assert(r.failures.isEmpty(), 'Removing a seat nobody had is not a failure.');
    }

    @isTest
    static void revokeLicences_asNonAdmin_isRefused() {
        User u = standardUser();
        Boolean refused = false;

        Test.startTest();
        System.runAs(u) {
            try {
                SignForceLicenceController.revokeLicences(new List<Id>{ u.Id });
            } catch (Exception e) {
                refused = true;
            }
        }
        Test.stopTest();

        System.assert(refused, 'Only an administrator may take seats away.');
    }
}