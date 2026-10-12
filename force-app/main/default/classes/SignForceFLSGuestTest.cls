/**
 * SignForceFLSGuestTest - coverage for SignForceFLSGuest (guest-side copy of the SignForceFLS
 * methods used by OTPService): requireAccessible pass/throw, bypassRequired (moved from
 * SignForceFLSTest), and the exception TYPE, which must remain SignForceFLS.SignForceFLSException.
 */
@isTest
private class SignForceFLSGuestTest {

    @isTest
    static void requireAccessible_passesWhenAccessible() {
        Boolean thrown = false;
        try {
            SignForceFLSGuest.requireAccessible(Agreement__c.SObjectType);
        } catch (SignForceFLS.SignForceFLSException e) {
            thrown = true;
        }
        System.assertEquals(false, thrown, 'Should not throw when the object is readable');
    }

    @isTest
    static void requireAccessible_throwsOriginalExceptionTypeWhenNotReadable() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String uniq = String.valueOf(DateTime.now().getTime()) + String.valueOf(Math.round(Math.random() * 100000));
        User u = new User(
            FirstName = 'Fls', LastName = 'Guest' + uniq, Email = 'fls' + uniq + '@example.com',
            Username = 'fls' + uniq + '@esignforce.test', Alias = 'flsg', ProfileId = p.Id,
            TimeZoneSidKey = 'America/Los_Angeles', LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8', LanguageLocaleKey = 'en_US'
        );
        insert u;
        System.runAs(u) {
            Boolean readable = Agreement__c.SObjectType.getDescribe().isAccessible();
            Boolean thrown = false;
            String msg = '';
            try {
                SignForceFLSGuest.requireAccessible(Agreement__c.SObjectType);
            } catch (SignForceFLS.SignForceFLSException e) {
                thrown = true;
                msg = e.getMessage();
            }
            System.assertEquals(!readable, thrown, 'Throws exactly when the user cannot read the object');
            if (thrown) {
                System.assert(msg.contains('read'), 'Message should mention the read action');
                System.assert(msg.contains('Contact your administrator'), 'Message should keep the admin hint');
            }
        }
    }

    // ─── bypassRequired Tests ──────────────────────────────────────────────────

    @isTest
    static void testBypassRequired_LogsWithoutException() {
        Boolean exceptionThrown = false;
        try {
            Test.startTest();
            SignForceFLSGuest.bypassRequired('Guest signing context — audit log write');
            Test.stopTest();
        } catch (Exception e) {
            exceptionThrown = true;
        }
        System.assertEquals(false, exceptionThrown, 'bypassRequired should never throw');
    }

    @isTest
    static void testBypassRequired_HandlesEmptyReason() {
        Boolean exceptionThrown = false;
        try {
            Test.startTest();
            SignForceFLSGuest.bypassRequired('');
            Test.stopTest();
        } catch (Exception e) {
            exceptionThrown = true;
        }
        System.assertEquals(false, exceptionThrown, 'Should handle empty reason without throwing');
    }

    @isTest
    static void testBypassRequired_HandlesNullReason() {
        Boolean exceptionThrown = false;
        try {
            Test.startTest();
            SignForceFLSGuest.bypassRequired(null);
            Test.stopTest();
        } catch (Exception e) {
            exceptionThrown = true;
        }
        System.assertEquals(false, exceptionThrown, 'Should handle null reason without throwing');
    }
}
