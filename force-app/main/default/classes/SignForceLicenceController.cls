/**
 * SignForceLicenceController — package-licence seats for the Admin Panel.
 *
 * A user needs TWO things to actually use eSignforce:
 *   1. a package LICENCE  (a seat — this class), and
 *   2. the SignForce User PERMISSION SET (functional access — handled by
 *      SignForceAdminConfigController's Internal Users step).
 *
 * Granting only one of them is the usual cause of "I have the app but every
 * screen errors" (licence, no perm set) or "the app is not in my App Launcher"
 * (perm set, no licence), so this screen reports BOTH per user and lets an
 * administrator fix either.
 *
 * SECURITY: every @AuraEnabled entry point calls requireAdmin(). Reading the
 * user roster and changing seat assignments are both administrator actions.
 *
 * NOTE ON THE PACKAGING ORG: a package has no PackageLicense record for its own
 * namespace in the org that develops it — you do not licence yourself. Every
 * read here degrades to a clearly-flagged "not licence managed" state instead of
 * throwing, so the screen still renders while developing.
 */
public with sharing class SignForceLicenceController {

    /** Salesforce uses -1 in AllowedLicenses to mean a site-wide (unlimited) licence. */
    private static final Integer UNLIMITED = -1;
    private static final Integer MAX_ROWS  = 200;

    // ─────────────────────────────────────────────────────────── wrappers

    public class SeatSummary {
        @AuraEnabled public Boolean licenceManaged = false;  // false in the packaging org
        @AuraEnabled public Boolean unlimited      = false;
        @AuraEnabled public Integer allowed        = 0;
        @AuraEnabled public Integer used           = 0;
        @AuraEnabled public Integer remaining      = 0;
        @AuraEnabled public Integer percentUsed    = 0;
        @AuraEnabled public String  status;
        // PackageLicense.ExpirationDate is a Datetime, not a Date.
        @AuraEnabled public Datetime expirationDate;
        @AuraEnabled public Boolean expiringSoon   = false;
        @AuraEnabled public String  note;
    }

    public class SeatUser {
        @AuraEnabled public Id      userId;
        @AuraEnabled public String  name;
        @AuraEnabled public String  username;
        @AuraEnabled public String  email;
        @AuraEnabled public String  profileName;
        @AuraEnabled public Boolean hasLicence  = false;
        @AuraEnabled public Boolean hasPermSet  = false;
        /** true only when the user can both see the app and use it. */
        @AuraEnabled public Boolean ready       = false;
        /** Plain-English description of what is missing, for the UI. */
        @AuraEnabled public String  state;
    }

    public class LicencePage {
        @AuraEnabled public SeatSummary    summary;
        @AuraEnabled public List<SeatUser> users = new List<SeatUser>();
    }

    public class SeatResult {
        @AuraEnabled public Integer succeeded = 0;
        @AuraEnabled public List<String> failures = new List<String>();
        @AuraEnabled public SeatSummary summary;
    }

    // ─────────────────────────────────────────────────────────── reads

    /**
     * Seat counts plus the internal user roster, each row marked with whether it
     * holds the licence, the permission set, or neither.
     */
    @AuraEnabled
    public static LicencePage getLicencePage() {
        requireAdmin();
        LicencePage page = new LicencePage();
        page.summary = buildSummary();

        PackageLicense pl = findPackageLicense();
        Set<Id> licensed = new Set<Id>();
        if (pl != null) {
            for (UserPackageLicense upl : [
                SELECT UserId FROM UserPackageLicense
                WHERE PackageLicenseId = :pl.Id
            ]) {
                licensed.add(upl.UserId);
            }
        }

        Set<Id> withPermSet = permSetHolders();

        for (User u : [
            SELECT Id, Name, Username, Email, Profile.Name
            FROM User
            WHERE IsActive = true AND UserType = 'Standard'
            WITH USER_MODE
            ORDER BY Name
            LIMIT :MAX_ROWS
        ]) {
            SeatUser su = new SeatUser();
            su.userId      = u.Id;
            su.name        = u.Name;
            su.username    = u.Username;
            su.email       = u.Email;
            su.profileName = u.Profile != null ? u.Profile.Name : null;
            su.hasLicence  = licensed.contains(u.Id);
            su.hasPermSet  = withPermSet.contains(u.Id);
            su.ready       = su.hasLicence && su.hasPermSet;

            if (su.ready)                          su.state = 'Ready';
            else if (su.hasLicence)                su.state = 'Licence only — cannot use the app';
            else if (su.hasPermSet)                su.state = 'Permission set only — no seat';
            else                                   su.state = 'No access';

            page.users.add(su);
        }
        return page;
    }

    // ─────────────────────────────────────────────────────────── writes

    /**
     * Grants a seat to each user. Users who already hold one are skipped rather
     * than failed, so re-running is safe.
     *
     * UserPackageLicense is a setup object: this method performs no other DML so
     * it can never hit MIXED_DML.
     */
    @AuraEnabled
    public static SeatResult assignLicences(List<Id> userIds) {
        requireAdmin();
        SeatResult res = new SeatResult();
        if (userIds == null || userIds.isEmpty()) {
            res.summary = buildSummary();
            return res;
        }

        PackageLicense pl = findPackageLicense();
        if (pl == null) {
            throw userError(
                'This org has no eSignforce package licence to assign. That is normal in the '
                + 'org where the package is developed; in a customer org it means the package '
                + 'is not licence managed.');
        }

        // Refuse rather than half-apply: an admin ticking 10 users with 3 seats
        // left should be told, not left guessing which 3 landed.
        if (pl.AllowedLicenses != UNLIMITED) {
            Integer free = pl.AllowedLicenses - pl.UsedLicenses;
            Integer wanted = countUnlicensed(pl.Id, userIds);
            if (wanted > free) {
                throw userError(
                    'Not enough seats: ' + wanted + ' selected user' + (wanted == 1 ? '' : 's')
                    + ' need a licence but only ' + free + ' remain' + (free == 1 ? 's' : '')
                    + '. Remove a licence from someone else, or buy more seats.');
            }
        }

        Set<Id> already = new Set<Id>();
        for (UserPackageLicense upl : [
            SELECT UserId FROM UserPackageLicense
            WHERE PackageLicenseId = :pl.Id AND UserId IN :userIds
        ]) {
            already.add(upl.UserId);
        }

        List<UserPackageLicense> toAdd = new List<UserPackageLicense>();
        for (Id uid : new Set<Id>(userIds)) {
            if (already.contains(uid)) continue;
            toAdd.add(new UserPackageLicense(PackageLicenseId = pl.Id, UserId = uid));
        }
        if (!toAdd.isEmpty()) {
            Database.SaveResult[] srs = Database.insert(toAdd, false);
            for (Integer i = 0; i < srs.size(); i++) {
                if (srs[i].isSuccess()) res.succeeded++;
                else res.failures.add(describeFailure(toAdd[i].UserId, srs[i].getErrors()));
            }
        }
        res.summary = buildSummary();
        return res;
    }

    /** Frees seats. Silently ignores users who never had one. */
    @AuraEnabled
    public static SeatResult revokeLicences(List<Id> userIds) {
        requireAdmin();
        SeatResult res = new SeatResult();
        if (userIds == null || userIds.isEmpty()) {
            res.summary = buildSummary();
            return res;
        }

        PackageLicense pl = findPackageLicense();
        if (pl == null) {
            res.summary = buildSummary();
            return res;
        }

        List<UserPackageLicense> toRemove = [
            SELECT Id, UserId FROM UserPackageLicense
            WHERE PackageLicenseId = :pl.Id AND UserId IN :userIds
        ];
        if (!toRemove.isEmpty()) {
            Database.DeleteResult[] drs = Database.delete(toRemove, false);
            for (Integer i = 0; i < drs.size(); i++) {
                if (drs[i].isSuccess()) res.succeeded++;
                else res.failures.add(describeFailure(toRemove[i].UserId, drs[i].getErrors()));
            }
        }
        res.summary = buildSummary();
        return res;
    }

    // ─────────────────────────────────────────────────────────── internals

    private static SeatSummary buildSummary() {
        SeatSummary s = new SeatSummary();
        PackageLicense pl = findPackageLicense();

        if (pl == null) {
            s.licenceManaged = false;
            s.note = 'No package license exists in this org. Please verify that the eSignforce '
                   + 'package has been installed with the required licensing configuration, or '
                   + 'contact your Salesforce administrator for assistance.';
            return s;
        }

        s.licenceManaged = true;
        s.status         = pl.Status;
        s.expirationDate = pl.ExpirationDate;
        s.used           = pl.UsedLicenses;
        s.unlimited      = (pl.AllowedLicenses == UNLIMITED);

        if (s.unlimited) {
            s.allowed   = UNLIMITED;
            s.remaining = UNLIMITED;
            s.note      = 'Site-wide licence — every user in this org can be given a seat.';
        } else {
            s.allowed     = pl.AllowedLicenses;
            s.remaining   = Math.max(0, pl.AllowedLicenses - pl.UsedLicenses);
            s.percentUsed = pl.AllowedLicenses == 0
                ? 0
                : Integer.valueOf(((Decimal) pl.UsedLicenses / pl.AllowedLicenses * 100)
                      .setScale(0, System.RoundingMode.HALF_UP));
        }

        if (pl.ExpirationDate != null) {
            Integer daysLeft = Date.today().daysBetween(pl.ExpirationDate.date());
            s.expiringSoon = (daysLeft >= 0 && daysLeft <= 30);
        }
        return s;
    }

    // @TestVisible so tests can stand in a PackageLicense. That object is a
    // read-only setup entity - it cannot be inserted, even in a test - so seat
    // arithmetic is otherwise unreachable. Tests deserialize a fake and set these
    // two directly; no production path ever writes them.
    @TestVisible private static Boolean plLoaded = false;
    @TestVisible private static PackageLicense cachedPl;
    /**
     * Wizard hook, called BEFORE a seat-carrying permission set is assigned:
     * give each user a licence seat. No-op when the org has no package licence
     * (the packaging org, or an org that is not licence managed). Throws when
     * seats run short or a seat insert fails, so the caller assigns NOTHING
     * rather than granting access without a seat.
     */
    public static void ensureSeats(List<Id> userIds) {
        if (userIds == null || userIds.isEmpty()) return;
        PackageLicense pl = findPackageLicense();
        if (pl == null) return;

        if (pl.AllowedLicenses != UNLIMITED) {
            Integer free = pl.AllowedLicenses - pl.UsedLicenses;
            Integer wanted = countUnlicensed(pl.Id, userIds);
            if (wanted > free) {
                throw userError(
                    'Not enough licences: ' + wanted + ' selected user' + (wanted == 1 ? '' : 's')
                    + ' need' + (wanted == 1 ? 's' : '') + ' a seat but only ' + free + ' remain'
                    + (free == 1 ? 's' : '') + '. The permission set was not assigned — free a '
                    + 'seat or buy more licences first.');
            }
        }

        Set<Id> already = new Set<Id>();
        for (UserPackageLicense upl : [
            SELECT UserId FROM UserPackageLicense
            WHERE PackageLicenseId = :pl.Id AND UserId IN :userIds
        ]) {
            already.add(upl.UserId);
        }
        List<UserPackageLicense> toAdd = new List<UserPackageLicense>();
        for (Id uid : new Set<Id>(userIds)) {
            if (!already.contains(uid)) {
                toAdd.add(new UserPackageLicense(PackageLicenseId = pl.Id, UserId = uid));
            }
        }
        // allOrNone: a seat that cannot be granted must block the permission set
        // assignment that depends on it.
        if (!toAdd.isEmpty()) insert toAdd;
    }

    /**
     * Frees the seats of users who no longer hold ANY seat-carrying permission
     * set (Admin or Standard) — called after removals so someone downgraded
     * from Admin to Standard keeps their seat. Best-effort by design.
     */
    public static void releaseSeatsIfUnused(List<Id> userIds) {
        if (userIds == null || userIds.isEmpty()) return;
        PackageLicense pl = findPackageLicense();
        if (pl == null) return;

        String ns = packageNs();
        Set<Id> stillSeated = new Set<Id>();
        for (PermissionSetAssignment psa : [
            SELECT AssigneeId FROM PermissionSetAssignment
            WHERE PermissionSet.Name IN ('SignForce_Admin', 'SignForce_User')
              AND PermissionSet.NamespacePrefix = :ns
              AND AssigneeId IN :userIds
            WITH USER_MODE
        ]) {
            stillSeated.add(psa.AssigneeId);
        }
        List<Id> toFree = new List<Id>();
        for (Id uid : new Set<Id>(userIds)) {
            if (!stillSeated.contains(uid)) toFree.add(uid);
        }
        if (toFree.isEmpty()) return;
        List<UserPackageLicense> upls = [
            SELECT Id FROM UserPackageLicense
            WHERE PackageLicenseId = :pl.Id AND UserId IN :toFree
        ];
        if (!upls.isEmpty()) Database.delete(upls, false);
    }

    private static PackageLicense findPackageLicense() {
        if (plLoaded) return cachedPl;
        plLoaded = true;
        String ns = packageNs();
        if (String.isBlank(ns)) { cachedPl = null; return null; }
        try {
            List<PackageLicense> pls = [
                SELECT Id, NamespacePrefix, AllowedLicenses, UsedLicenses, ExpirationDate, Status
                FROM PackageLicense
                WHERE NamespacePrefix = :ns
                LIMIT 1
            ];
            cachedPl = pls.isEmpty() ? null : pls[0];
        } catch (Exception e) {
            cachedPl = null;
        }
        return cachedPl;
    }

    /** Users holding this package's SignForce User permission set. */
    private static Set<Id> permSetHolders() {
        Set<Id> out = new Set<Id>();
        String ns = packageNs();
        List<PermissionSet> ps = [
            SELECT Id FROM PermissionSet
            WHERE Name = 'SignForce_User' AND NamespacePrefix = :ns
            WITH USER_MODE LIMIT 1
        ];
        if (ps.isEmpty()) return out;
        for (PermissionSetAssignment psa : [
            SELECT AssigneeId FROM PermissionSetAssignment
            WHERE PermissionSetId = :ps[0].Id
            WITH USER_MODE
        ]) {
            out.add(psa.AssigneeId);
        }
        return out;
    }

    private static Integer countUnlicensed(Id packageLicenseId, List<Id> userIds) {
        Set<Id> have = new Set<Id>();
        for (UserPackageLicense upl : [
            SELECT UserId FROM UserPackageLicense
            WHERE PackageLicenseId = :packageLicenseId AND UserId IN :userIds
        ]) {
            have.add(upl.UserId);
        }
        Integer n = 0;
        for (Id uid : new Set<Id>(userIds)) {
            if (!have.contains(uid)) n++;
        }
        return n;
    }

    private static String describeFailure(Id userId, List<Database.Error> errs) {
        String msg = errs != null && !errs.isEmpty() ? errs[0].getMessage() : 'Unknown error';
        return String.valueOf(userId) + ': ' + msg;
    }

    // Namespace of this package. NOTE: this is 'esignforce' in BOTH a subscriber
    // org and the packaging org - it does NOT distinguish the two.
    private static Boolean nsLoaded = false;
    private static String cachedNs;
    @TestVisible
    private static String packageNs() {
        if (nsLoaded) return cachedNs;
        nsLoaded = true;
        try {
            cachedNs = [
                SELECT NamespacePrefix FROM ApexClass
                WHERE Name = 'SignForceLicenceController' WITH USER_MODE LIMIT 1
            ].NamespacePrefix;
        } catch (Exception e) {
            cachedNs = null;
        }
        return cachedNs;
    }

    private static Boolean isCurrentUserAdmin() {
        try {
            return FeatureManagement.checkPermission('CustomizeApplication')
                || [SELECT PermissionsCustomizeApplication FROM Profile
                    WHERE Id = :UserInfo.getProfileId() LIMIT 1].PermissionsCustomizeApplication;
        } catch (Exception e) {
            return false;
        }
    }

    /**
     * AuraHandledException keeps its message for the LWC but reports
     * "Script-thrown exception" from getMessage() in Apex and in debug logs.
     * setMessage() puts the real text back, so failures stay diagnosable.
     */
    private static AuraHandledException userError(String msg) {
        AuraHandledException e = new AuraHandledException(msg);
        e.setMessage(msg);
        return e;
    }

    private static void requireAdmin() {
        if (!isCurrentUserAdmin()) {
            throw userError(
                'Administrator permission (Customize Application) is required for this action.'
            );
        }
    }
}