/**
 * SignForceAdminConfigController
 * --------------------------------
 * Backs the "signforceAdminConfig" LWC — the post-install admin configuration
 * screen for the SignForce managed package.
 *
 * Responsibilities:
 *   1. Read / write org-specific config to the SignForce_Admin_Config__c
 *      hierarchy custom setting (org-default record). DML on a custom setting is
 *      synchronous, so the LWC can save directly (unlike Custom Metadata, which
 *      needs the async Metadata API).
 *   2. Auto-detect the org's Experience Cloud sites so the admin can pick the
 *      signing-site URL from a dropdown instead of pasting it.
 *   3. List verified Org-Wide Email Addresses for the sender dropdown.
 *   4. Report package permission-set assignment status and assign the internal
 *      permission set to all active internal users in one click.
 *
 * SECURITY: every @AuraEnabled entry point calls requireAdmin() so only users
 * with "Customize Application" (administrators) can read config / user rosters
 * or change assignments. SOQL uses WITH USER_MODE and DML uses
 * AccessLevel.USER_MODE to enforce CRUD/FLS in the caller's context.
 */
public with sharing class SignForceAdminConfigController {

    private static final Integer MAX_DML_ROWS = 10000; // per-transaction DML row cap

    // ---- Config read/write ---------------------------------------------------

    public class ConfigWrapper {
        @AuraEnabled public String signingSiteBaseUrl;
        @AuraEnabled public String portalAccountId;
        @AuraEnabled public String orgWideEmailId;
        @AuraEnabled public String defaultStorageTier;
        // 'OrgWide' (default) or 'CurrentUser' — see AgreementService.getOwaId.
        @AuraEnabled public String senderEmailMode;
    }

    @AuraEnabled(cacheable=true)
    public static ConfigWrapper getConfig() {
        requireAdmin();
        SignForce_Admin_Config__c cs = SignForce_Admin_Config__c.getOrgDefaults();
        ConfigWrapper w = new ConfigWrapper();
        if (cs != null) {
            w.signingSiteBaseUrl = cs.Signing_Site_Base_URL__c;
            w.portalAccountId     = cs.Portal_Account_Id__c;
            w.orgWideEmailId      = cs.Org_Wide_Email_Id__c;
            w.defaultStorageTier  = cs.Default_Storage_Tier__c;
            w.senderEmailMode     = String.isBlank(cs.Sender_Email_Mode__c)
                ? AgreementService.SENDER_MODE_ORG_WIDE
                : cs.Sender_Email_Mode__c;
        }
        return w;
    }

    @AuraEnabled
    public static void saveConfig(String signingSiteBaseUrl, String portalAccountId,
                                  String orgWideEmailId, String defaultStorageTier,
                                  String senderEmailMode) {
        requireAdmin();
        SignForce_Admin_Config__c cs;
        List<SignForce_Admin_Config__c> existing = [
            SELECT Id FROM SignForce_Admin_Config__c
            WHERE SetupOwnerId = :UserInfo.getOrganizationId() WITH USER_MODE LIMIT 1
        ];
        if (!existing.isEmpty()) {
            cs = existing[0];
        } else {
            cs = new SignForce_Admin_Config__c(SetupOwnerId = UserInfo.getOrganizationId());
        }
        cs.Signing_Site_Base_URL__c = trimToNull(signingSiteBaseUrl);
        cs.Portal_Account_Id__c     = trimToNull(portalAccountId);
        cs.Org_Wide_Email_Id__c     = trimToNull(orgWideEmailId);
        cs.Default_Storage_Tier__c  = trimToNull(defaultStorageTier);
        // Anything other than the explicit "send as the user" value means the
        // org-wide address, so an unrecognised value can never silently change
        // who emails come from.
        cs.Sender_Email_Mode__c     =
            AgreementService.SENDER_MODE_CURRENT_USER.equals(trimToNull(senderEmailMode))
                ? AgreementService.SENDER_MODE_CURRENT_USER
                : AgreementService.SENDER_MODE_ORG_WIDE;
        Database.upsert(cs, SignForce_Admin_Config__c.Id, true, AccessLevel.USER_MODE);
    }

    // ---- Experience site auto-detect -----------------------------------------

    /**
     * Best-effort list of the org's site URLs (domain + path prefix) for the
     * dropdown. Uses DomainSite, which maps each site to its external domain.
     * If the objects aren't accessible (or none exist) we return an empty list
     * and the admin types the URL manually.
     */
    @AuraEnabled(cacheable=true)
    public static List<Option> getSites() {
        requireAdmin();
        try {
            return mapSites([
                SELECT PathPrefix, Domain.Domain, Site.Name, Site.SiteType, Site.Status
                FROM DomainSite
                WITH USER_MODE
                ORDER BY Domain.Domain
                // Bounded on purpose. This feeds a picker an admin reads, and an
                // org has a handful of sites, never hundreds — the limit costs
                // nothing here and takes the query out of the unbounded-SOQL
                // finding.
                LIMIT 200
            ]);
        } catch (Exception e) {
            // Domain/DomainSite not visible in this org/context — fall back to manual entry.
            System.debug('getSites failed: ' + e.getMessage());
            return new List<Option>();
        }
    }

    // Site.SiteType values for classic (non-LWR) sites that must NOT appear in the
    // signing-site picker: 'Visualforce' = Force.com Site, 'ChatterNetwork' = classic
    // community. LWR / Experience Builder sites are 'ChatterNetworkPicasso'.
    private static final Set<String> CLASSIC_SITE_TYPES = new Set<String>{
        'Visualforce', 'ChatterNetwork'
    };

    // Salesforce has no "Archived" status: archiving/deactivating a site sets
    // Site.Status to 'Inactive'. Such a site still has a DomainSite row and so
    // still appears in the picker, but its URL serves nothing — picking it
    // produces a signing link that silently fails. Only 'Active' is selectable.
    private static final String SITE_STATUS_ACTIVE = 'Active';

    @TestVisible
    private static List<Option> mapSites(List<DomainSite> rows) {
        List<Option> out = new List<Option>();
        for (DomainSite ds : rows) {
            if (ds.Domain == null || String.isBlank(ds.Domain.Domain)) continue;
            // Only LWR / Experience Builder sites ('ChatterNetworkPicasso') can host
            // the signing page. Skip classic Force.com Sites ('Visualforce') and
            // classic communities ('ChatterNetwork') — e.g. /signvforcesite — which
            // don't run the signingViewer and only confuse admins.
            if (ds.Site != null && CLASSIC_SITE_TYPES.contains(ds.Site.SiteType)) continue;
            // Skip archived / deactivated sites. Only an explicit non-Active status
            // hides a row — a blank status means "couldn't tell", and hiding a site
            // we failed to classify would be worse than showing it.
            if (ds.Site != null
                && String.isNotBlank(ds.Site.Status)
                && ds.Site.Status != SITE_STATUS_ACTIVE) continue;
            String url = 'https://' + ds.Domain.Domain;
            if (String.isNotBlank(ds.PathPrefix)) {
                url += ds.PathPrefix.startsWith('/') ? ds.PathPrefix : '/' + ds.PathPrefix;
            }
            String name = (ds.Site != null && String.isNotBlank(ds.Site.Name))
                ? ds.Site.Name : ds.Domain.Domain;
            out.add(new Option(name + '  —  ' + url, url));
        }
        return out;
    }

    @AuraEnabled(cacheable=true)
    public static List<Option> getOrgWideEmails() {
        requireAdmin();
        return mapOwa([
            SELECT Id, Address, DisplayName FROM OrgWideEmailAddress
            WITH USER_MODE ORDER BY DisplayName
            // Same reasoning as getSites: a picker, and an org has a few
            // verified addresses at most.
            LIMIT 200
        ]);
    }

    @TestVisible
    private static List<Option> mapOwa(List<OrgWideEmailAddress> rows) {
        List<Option> out = new List<Option>();
        for (OrgWideEmailAddress o : rows) {
            String label = (String.isNotBlank(o.DisplayName) ? o.DisplayName + ' ' : '')
                           + '<' + o.Address + '>';
            out.add(new Option(label, o.Id));
        }
        return out;
    }

    // ---- Permission set assignment -------------------------------------------

    public class PermSetInfo {
        @AuraEnabled public String  name;          // API name (namespaced)
        @AuraEnabled public String  label;
        @AuraEnabled public Integer assigned;       // active internal users with it
        @AuraEnabled public Integer totalInternal;  // active internal users total
        @AuraEnabled public Boolean assignable;     // false => guest, info only
        @AuraEnabled public String  note;
        @AuraEnabled public List<String> assignedNames = new List<String>(); // names of assigned users (capped)
    }

    // Bare permission-set API names shipped by this package.
    private static final Set<String> GUEST_PERMSETS    = new Set<String>{ 'SignForce_Guest_User_Access' };
    private static final Set<String> INTERNAL_PERMSETS = new Set<String>{ 'SignForce_Admin', 'SignForce_User', 'Agentforce_SignForce_User' };
    // Perm sets that only make sense when Agentforce is available — hidden from the
    // wizard in orgs without it, so admins don't assign an unusable set.
    private static final Set<String> AGENTFORCE_PERMSETS = new Set<String>{ 'Agentforce_SignForce_User' };

    @AuraEnabled
    public static List<PermSetInfo> getPermissionSetStatus() {
        requireAdmin();
        // PermissionSet.Name (DeveloperName) is ALWAYS bare ('SignForce_User') —
        // even in a subscriber org the namespace lives in the separate
        // NamespacePrefix field, NOT in Name. Filter on NamespacePrefix so we
        // target THIS package's perm sets and never a subscriber's same-named one.
        String ns = packageNs();
        Set<String> bareNames = new Set<String>();
        bareNames.addAll(INTERNAL_PERMSETS);
        bareNames.addAll(GUEST_PERMSETS);

        // Drop Agentforce-only perm sets when this org has no Agentforce.
        if (!SignForceAccess.isAgentforceAvailable()) {
            bareNames.removeAll(AGENTFORCE_PERMSETS);
        }

        Integer totalInternal = [
            SELECT COUNT() FROM User WHERE IsActive = true AND UserType = 'Standard'
            WITH USER_MODE
        ];

        List<PermSetInfo> result = new List<PermSetInfo>();
        for (PermissionSet ps : [
            SELECT Id, Name, Label FROM PermissionSet
            WHERE Name IN :bareNames AND NamespacePrefix = :ns
            WITH USER_MODE ORDER BY Label
        ]) {
            PermSetInfo i = new PermSetInfo();
            i.name  = ps.Name;
            i.label = ps.Label;
            if (endsWithAny(ps.Name, GUEST_PERMSETS)) {
                i.assignable = false;
                i.note = 'For your Experience site Guest User only. Assign it on the site\'s '
                       + 'Guest User profile (Setup → Digital Experiences → [site] → '
                       + 'Administration → Pages → Guest User Profile), not to internal users.';
                // Guest users are UserType='Guest' — surface their assignment in Review.
                i.assigned = [
                    SELECT COUNT() FROM PermissionSetAssignment
                    WHERE PermissionSetId = :ps.Id
                      AND Assignee.IsActive = true
                      AND Assignee.UserType = 'Guest'
                    WITH USER_MODE
                ];
                for (PermissionSetAssignment psa : [
                    SELECT Assignee.Name FROM PermissionSetAssignment
                    WHERE PermissionSetId = :ps.Id
                      AND Assignee.IsActive = true
                      AND Assignee.UserType = 'Guest'
                    WITH USER_MODE
                    ORDER BY Assignee.Name LIMIT 50
                ]) {
                    i.assignedNames.add(psa.Assignee.Name);
                }
            } else {
                i.assignable = true;
                i.totalInternal = totalInternal;
                i.assigned = [
                    SELECT COUNT() FROM PermissionSetAssignment
                    WHERE PermissionSetId = :ps.Id
                      AND Assignee.IsActive = true
                      AND Assignee.UserType = 'Standard'
                    WITH USER_MODE
                ];
                // Names of the assigned users, capped so a big rollout can't bloat
                // the Review payload. The count above stays exact.
                for (PermissionSetAssignment psa : [
                    SELECT Assignee.Name FROM PermissionSetAssignment
                    WHERE PermissionSetId = :ps.Id
                      AND Assignee.IsActive = true
                      AND Assignee.UserType = 'Standard'
                    WITH USER_MODE
                    ORDER BY Assignee.Name LIMIT 50
                ]) {
                    i.assignedNames.add(psa.Assignee.Name);
                }
            }
            result.add(i);
        }
        return result;
    }

    // True if name equals a bare name, or ends with '__<bare>' (namespaced form).
    private static Boolean endsWithAny(String name, Set<String> bareNames) {
        for (String b : bareNames) {
            if (name == b || name.endsWith('__' + b)) return true;
        }
        return false;
    }

    // True only for this package's own permission sets (bare or namespaced).
    private static Boolean isPackagePermSet(String name) {
        if (String.isBlank(name)) return false;
        return endsWithAny(name, INTERNAL_PERMSETS) || endsWithAny(name, GUEST_PERMSETS);
    }

    private static Boolean isDuplicate(List<Database.Error> errs) {
        if (errs == null) return false;
        for (Database.Error e : errs) {
            if (e.getStatusCode() == StatusCode.DUPLICATE_VALUE) return true;
        }
        return false;
    }

    private static String firstError(List<Database.Error> errs) {
        return (errs != null && !errs.isEmpty()) ? errs[0].getMessage() : 'Unknown error';
    }

    public class AssignResult {
        @AuraEnabled public Integer assigned        = 0;
        @AuraEnabled public Integer removed         = 0;
        @AuraEnabled public Integer failed          = 0;
        @AuraEnabled public Integer alreadyAssigned = 0;
        @AuraEnabled public String  message;
        @AuraEnabled public List<String> failures   = new List<String>(); // "User Name: reason"
    }

    /**
     * All active internal (UserType = 'Standard') users as options for the
     * dual-listbox source. value = User Id, label = "Name (Username)".
     */
    // Users are identified by their Salesforce USER LICENCE, not UserType:
    // UserType 'Standard' cannot tell full CRM from Platform, the licence can.
    private static final Set<String> FULL_LICENCE_KEYS = new Set<String>{ 'SFDC' };
    private static final Set<String> INTERNAL_LICENCE_KEYS = new Set<String>{ 'SFDC', 'AUL', 'AUL1' };

    @AuraEnabled
    public static List<Option> getInternalUsers() {
        requireAdmin();
        List<Option> out = new List<Option>();
        // Membership = every active INTERNAL user (UserType 'Standard' covers
        // both full-Salesforce and Platform licences; community/guest are their
        // own types). Filtering by licence key in the WHERE was too narrow and
        // could also trip USER_MODE on the UserLicense traversal, leaving the
        // list empty — so we scope by UserType and only READ the licence for the
        // display label. LIMIT guards the 50k row cap / heap in large orgs.
        for (User u : [
            SELECT Id, Name, Username, Profile.UserLicense.Name, Profile.UserLicense.LicenseDefinitionKey
            FROM User
            WHERE IsActive = true AND UserType = 'Standard'
            WITH USER_MODE
            ORDER BY Name
            LIMIT 5000
        ]) {
            String lic = (u.Profile != null && u.Profile.UserLicense != null)
                ? u.Profile.UserLicense.Name : null;
            String key = (u.Profile != null && u.Profile.UserLicense != null)
                ? u.Profile.UserLicense.LicenseDefinitionKey : null;
            String label = u.Name + ' (' + u.Username + ')'
                + (String.isNotBlank(lic) ? ' — ' + lic : '');
            out.add(new Option(label, u.Id, key));
        }
        return out;
    }

    /** Active authenticated Experience Cloud (community/portal) users. */
    @AuraEnabled
    public static List<Option> getCommunityUsers() {
        requireAdmin();
        List<Option> out = new List<Option>();
        for (User u : [
            SELECT Id, Name, Username, Profile.UserLicense.Name, Profile.UserLicense.LicenseDefinitionKey
            FROM User
            WHERE IsActive = true
              AND Profile.UserLicense.LicenseDefinitionKey LIKE '%Community%'
            WITH USER_MODE
            ORDER BY Name
            LIMIT 5000
        ]) {
            out.add(new Option(
                u.Name + ' (' + u.Username + ') — ' + u.Profile.UserLicense.Name,
                u.Id,
                u.Profile.UserLicense.LicenseDefinitionKey));
        }
        return out;
    }

    // Authenticated Experience Cloud licence types. Guest stays its own step.
    private static final List<String> COMMUNITY_USER_TYPES = new List<String>{
        'PowerPartner', 'PowerCustomerSuccess', 'CustomerSuccess', 'CspLitePortal'
    };

    /** User types a scope reconciles over: internal Standard, or community. */
    private static List<String> scopeUserTypes(String userScope) {
        return userScope == 'community' ? COMMUNITY_USER_TYPES : new List<String>{ 'Standard' };
    }

    // The two permission sets whose assignment consumes a licence seat. The
    // community tab hands out SignForce_User too, but community users sign in
    // through the site — only internal assignments are seat-checked.
    private static Boolean isSeatPermSet(String permSetName, String userScope) {
        return userScope != 'community'
            && (permSetName == 'SignForce_Admin' || permSetName == 'SignForce_User');
    }

    /**
     * User Ids currently assigned the given permission set (active users of the
     * requested scope only) — the "selected" side of the dual-listbox.
     */
    @AuraEnabled
    public static List<Id> getAssignedUserIds(String permSetName, String userScope) {
        requireAdmin();
        List<Id> ids = new List<Id>();
        // Only this package's own permission sets may be inspected through this
        // endpoint — prevents enumerating assignees of arbitrary org perm sets.
        if (!isPackagePermSet(permSetName)) return ids;
        String ns = packageNs();
        List<PermissionSet> ps = [
            SELECT Id FROM PermissionSet
            WHERE Name = :permSetName AND NamespacePrefix = :ns WITH USER_MODE LIMIT 1
        ];
        if (ps.isEmpty()) return ids;
        List<String> userTypes = scopeUserTypes(userScope);
        for (PermissionSetAssignment a : [
            SELECT AssigneeId FROM PermissionSetAssignment
            WHERE PermissionSetId = :ps[0].Id
              AND Assignee.IsActive = true
              AND Assignee.UserType IN :userTypes
            WITH USER_MODE
        ]) {
            ids.add(a.AssigneeId);
        }
        return ids;
    }

    /**
     * Reconciles the permission set's assignments to match selectedUserIds (the
     * right/"assigned" side of the dual-listbox):
     *   - adds assignments for selected users who don't have it,
     *   - removes assignments for currently-assigned users no longer selected.
     * Reconciles among ACTIVE INTERNAL users only (the only users the UI offers).
     * Per-row failures are collected (not fatal) and returned in result.failures
     * with the affected user name and reason.
     */
    @AuraEnabled
    public static AssignResult applyAssignments(String permSetName, List<Id> selectedUserIds, String userScope) {
        requireAdmin();
        AssignResult r = new AssignResult();

        if (!isPackagePermSet(permSetName)) {
            r.message = 'Permission set not found: ' + permSetName;
            return r;
        }
        String ns = packageNs();
        List<PermissionSet> ps = [
            SELECT Id FROM PermissionSet
            WHERE Name = :permSetName AND NamespacePrefix = :ns WITH USER_MODE LIMIT 1
        ];
        if (ps.isEmpty()) {
            r.message = 'Permission set not found: ' + permSetName;
            return r;
        }
        Id psId = ps[0].Id;

        Set<Id> desired = new Set<Id>();
        if (selectedUserIds != null) desired.addAll(selectedUserIds);

        // Current assignments for active users of the requested scope.
        List<String> userTypes = scopeUserTypes(userScope);
        Map<Id, Id> currentByUser = new Map<Id, Id>();    // userId -> assignmentId
        Map<Id, Id> userByAssignment = new Map<Id, Id>();  // assignmentId -> userId
        for (PermissionSetAssignment a : [
            SELECT Id, AssigneeId FROM PermissionSetAssignment
            WHERE PermissionSetId = :psId
              AND Assignee.IsActive = true
              AND Assignee.UserType IN :userTypes
            WITH USER_MODE
        ]) {
            currentByUser.put(a.AssigneeId, a.Id);
            userByAssignment.put(a.Id, a.AssigneeId);
        }

        List<PermissionSetAssignment> toAdd = new List<PermissionSetAssignment>();
        for (Id uid : desired) {
            if (!currentByUser.containsKey(uid)) {
                toAdd.add(new PermissionSetAssignment(PermissionSetId = psId, AssigneeId = uid));
            }
        }
        List<PermissionSetAssignment> toRemove = new List<PermissionSetAssignment>();
        for (Id uid : currentByUser.keySet()) {
            if (!desired.contains(uid)) {
                toRemove.add(new PermissionSetAssignment(Id = currentByUser.get(uid)));
            }
        }

        if (toAdd.size() + toRemove.size() > MAX_DML_ROWS) {
            throw new AuraHandledException(
                'Too many changes at once (' + (toAdd.size() + toRemove.size())
                + '). Please apply in smaller batches (max ' + MAX_DML_ROWS + ').'
            );
        }

        Map<Id, String> errorByUser = new Map<Id, String>();

        // Admin/Standard access consumes a licence seat: grant the seats FIRST.
        // ensureSeats throws when the org's seats run short (or a seat insert
        // fails), so no permission set lands without a licence behind it.
        if (isSeatPermSet(permSetName, userScope) && !toAdd.isEmpty()) {
            List<Id> newUserIds = new List<Id>();
            for (PermissionSetAssignment a : toAdd) newUserIds.add(a.AssigneeId);
            SignForceLicenceController.ensureSeats(newUserIds);
        }

        if (!toAdd.isEmpty()) {
            Database.SaveResult[] srs = Database.insert(toAdd, false, AccessLevel.USER_MODE);
            for (Integer i = 0; i < srs.size(); i++) {
                if (srs[i].isSuccess()) {
                    r.assigned++;
                } else if (isDuplicate(srs[i].getErrors())) {
                    r.alreadyAssigned++;            // already had it — not a failure
                } else {
                    r.failed++;
                    errorByUser.put(toAdd[i].AssigneeId, firstError(srs[i].getErrors()));
                }
            }
        }
        if (!toRemove.isEmpty()) {
            Database.DeleteResult[] drs = Database.delete(toRemove, false, AccessLevel.USER_MODE);
            for (Integer i = 0; i < drs.size(); i++) {
                if (drs[i].isSuccess()) {
                    r.removed++;
                } else {
                    r.failed++;
                    Id uid = userByAssignment.get(toRemove[i].Id);
                    if (uid != null) errorByUser.put(uid, firstError(drs[i].getErrors()));
                }
            }
        }

        // Runs AFTER the removal DML so the still-holding check sees the new
        // state; users downgraded Admin→Standard (or vice versa) keep the seat.
        if (isSeatPermSet(permSetName, userScope) && !toRemove.isEmpty()) {
            List<Id> removedIds = new List<Id>();
            for (PermissionSetAssignment a : toRemove) {
                Id uid = userByAssignment.get(a.Id);
                if (uid != null) removedIds.add(uid);
            }
            try {
                SignForceLicenceController.releaseSeatsIfUnused(removedIds);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'Seat release failed (non-fatal): ' + e.getMessage());
            }
        }

        if (!errorByUser.isEmpty()) {
            Map<Id, User> names = new Map<Id, User>([
                SELECT Id, Name FROM User WHERE Id IN :errorByUser.keySet() WITH USER_MODE
            ]);
            for (Id uid : errorByUser.keySet()) {
                String nm = names.containsKey(uid) ? names.get(uid).Name : String.valueOf(uid);
                r.failures.add(nm + ': ' + errorByUser.get(uid));
            }
        }

        r.message = r.assigned + ' added, ' + r.removed + ' removed, ' + r.failed + ' failed.';
        return r;
    }

    // ═════════════════════════════════════════════════════════════════════
    //  GUEST USER ASSIGNMENT (SignForce Guest User Access → site Guest User)
    // ═════════════════════════════════════════════════════════════════════

    /** Active Experience-site Guest Users (UserType = 'Guest') as listbox options. */
    @AuraEnabled
    public static List<Option> getGuestUsers() {
        requireAdmin();
        List<Option> out = new List<Option>();
        for (User u : [
            SELECT Id, Name, Username FROM User
            WHERE IsActive = true AND UserType = 'Guest'
            WITH USER_MODE
            ORDER BY Name
            LIMIT 1000
        ]) {
            out.add(new Option(u.Name + ' (' + u.Username + ')', u.Id));
        }
        return out;
    }

    /** Guest Users currently assigned the given (guest) permission set. */
    @AuraEnabled
    public static List<Id> getAssignedGuestUserIds(String permSetName) {
        requireAdmin();
        List<Id> ids = new List<Id>();
        if (!isPackagePermSet(permSetName)) return ids;
        String ns = packageNs();
        List<PermissionSet> ps = [
            SELECT Id FROM PermissionSet
            WHERE Name = :permSetName AND NamespacePrefix = :ns WITH USER_MODE LIMIT 1
        ];
        if (ps.isEmpty()) return ids;
        for (PermissionSetAssignment a : [
            SELECT AssigneeId FROM PermissionSetAssignment
            WHERE PermissionSetId = :ps[0].Id
              AND Assignee.IsActive = true
              AND Assignee.UserType = 'Guest'
            WITH USER_MODE
        ]) {
            ids.add(a.AssigneeId);
        }
        return ids;
    }

    /**
     * Reconciles GUEST-user assignments for the package's guest permission set
     * (add/remove to match selectedUserIds). Restricted to GUEST_PERMSETS so an
     * internal permission set can never be pushed onto a guest user. Per-row
     * failures (e.g. a license-incompatible perm set) are collected, not fatal.
     */
    @AuraEnabled
    public static AssignResult applyGuestAssignments(String permSetName, List<Id> selectedUserIds) {
        requireAdmin();
        AssignResult r = new AssignResult();

        if (!GUEST_PERMSETS.contains(permSetName)) {
            r.message = 'Only the eSignforce Guest User Access permission set can be assigned to guest users.';
            return r;
        }
        String ns = packageNs();
        List<PermissionSet> ps = [
            SELECT Id FROM PermissionSet
            WHERE Name = :permSetName AND NamespacePrefix = :ns WITH USER_MODE LIMIT 1
        ];
        if (ps.isEmpty()) {
            r.message = 'Permission set not found: ' + permSetName;
            return r;
        }
        Id psId = ps[0].Id;

        Set<Id> desired = new Set<Id>();
        if (selectedUserIds != null) desired.addAll(selectedUserIds);

        Map<Id, Id> currentByUser = new Map<Id, Id>();
        Map<Id, Id> userByAssignment = new Map<Id, Id>();
        for (PermissionSetAssignment a : [
            SELECT Id, AssigneeId FROM PermissionSetAssignment
            WHERE PermissionSetId = :psId
              AND Assignee.IsActive = true
              AND Assignee.UserType = 'Guest'
            WITH USER_MODE
        ]) {
            currentByUser.put(a.AssigneeId, a.Id);
            userByAssignment.put(a.Id, a.AssigneeId);
        }

        List<PermissionSetAssignment> toAdd = new List<PermissionSetAssignment>();
        for (Id uid : desired) {
            if (!currentByUser.containsKey(uid)) {
                toAdd.add(new PermissionSetAssignment(PermissionSetId = psId, AssigneeId = uid));
            }
        }
        List<PermissionSetAssignment> toRemove = new List<PermissionSetAssignment>();
        for (Id uid : currentByUser.keySet()) {
            if (!desired.contains(uid)) {
                toRemove.add(new PermissionSetAssignment(Id = currentByUser.get(uid)));
            }
        }

        if (toAdd.size() + toRemove.size() > MAX_DML_ROWS) {
            throw new AuraHandledException(
                'Too many changes at once. Please apply in smaller batches (max ' + MAX_DML_ROWS + ').'
            );
        }

        Map<Id, String> errorByUser = new Map<Id, String>();
        if (!toAdd.isEmpty()) {
            Database.SaveResult[] srs = Database.insert(toAdd, false, AccessLevel.USER_MODE);
            for (Integer i = 0; i < srs.size(); i++) {
                if (srs[i].isSuccess()) r.assigned++;
                else if (isDuplicate(srs[i].getErrors())) r.alreadyAssigned++;
                else { r.failed++; errorByUser.put(toAdd[i].AssigneeId, firstError(srs[i].getErrors())); }
            }
        }
        if (!toRemove.isEmpty()) {
            Database.DeleteResult[] drs = Database.delete(toRemove, false, AccessLevel.USER_MODE);
            for (Integer i = 0; i < drs.size(); i++) {
                if (drs[i].isSuccess()) r.removed++;
                else {
                    r.failed++;
                    Id uid = userByAssignment.get(toRemove[i].Id);
                    if (uid != null) errorByUser.put(uid, firstError(drs[i].getErrors()));
                }
            }
        }
        if (!errorByUser.isEmpty()) {
            Map<Id, User> names = new Map<Id, User>([
                SELECT Id, Name FROM User WHERE Id IN :errorByUser.keySet() WITH USER_MODE
            ]);
            for (Id uid : errorByUser.keySet()) {
                String nm = names.containsKey(uid) ? names.get(uid).Name : String.valueOf(uid);
                r.failures.add(nm + ': ' + errorByUser.get(uid));
            }
        }
        r.message = r.assigned + ' added, ' + r.removed + ' removed, ' + r.failed + ' failed.';
        return r;
    }

    /**
     * Assigns the given permission set to every active internal (UserType =
     * 'Standard') user who doesn't already have it. Per-user failures (e.g. a
     * user lacking a required feature license) are counted, not fatal.
     */
    @AuraEnabled
    public static AssignResult assignToAllInternalUsers(String permSetName) {
        requireAdmin();
        AssignResult r = new AssignResult();

        if (!isPackagePermSet(permSetName)) {
            r.message = 'Permission set not found: ' + permSetName;
            return r;
        }
        String ns = packageNs();
        List<PermissionSet> ps = [
            SELECT Id FROM PermissionSet
            WHERE Name = :permSetName AND NamespacePrefix = :ns WITH USER_MODE LIMIT 1
        ];
        if (ps.isEmpty()) {
            r.message = 'Permission set not found: ' + permSetName;
            return r;
        }
        Id psId = ps[0].Id;

        Set<Id> already = new Set<Id>();
        for (PermissionSetAssignment a : [
            SELECT AssigneeId FROM PermissionSetAssignment
            WHERE PermissionSetId = :psId WITH USER_MODE
        ]) {
            already.add(a.AssigneeId);
        }

        List<PermissionSetAssignment> toInsert = new List<PermissionSetAssignment>();
        for (User u : [
            SELECT Id FROM User WHERE IsActive = true AND UserType = 'Standard'
            WITH USER_MODE LIMIT 5000
        ]) {
            if (!already.contains(u.Id)) {
                toInsert.add(new PermissionSetAssignment(PermissionSetId = psId, AssigneeId = u.Id));
            }
        }
        r.alreadyAssigned = already.size();

        // Same seat gate as applyAssignments: a full-org rollout of Admin or
        // Standard access must not outrun the org's licence count.
        if (isSeatPermSet(permSetName, null) && !toInsert.isEmpty()) {
            List<Id> newUserIds = new List<Id>();
            for (PermissionSetAssignment a : toInsert) newUserIds.add(a.AssigneeId);
            SignForceLicenceController.ensureSeats(newUserIds);
        }

        if (toInsert.size() > MAX_DML_ROWS) {
            throw new AuraHandledException(
                'Too many users (' + toInsert.size() + ') to assign at once (max '
                + MAX_DML_ROWS + ').'
            );
        }
        if (!toInsert.isEmpty()) {
            for (Database.SaveResult sr : Database.insert(toInsert, false, AccessLevel.USER_MODE)) {
                if (sr.isSuccess()) { r.assigned++; } else { r.failed++; }
            }
        }
        r.message = r.assigned + ' newly assigned, ' + r.failed + ' failed, '
                  + r.alreadyAssigned + ' already had it.';
        return r;
    }

    // ---- helpers --------------------------------------------------------------

    public class Option {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
        // User lists only: the Salesforce user-licence key (SFDC, AUL, PID_*…)
        // so the role tabs can identify users by licence, not guesswork.
        @AuraEnabled public String licenseKey;
        public Option(String label, String value) { this.label = label; this.value = value; }
        public Option(String label, String value, String licenseKey) {
            this.label = label; this.value = value; this.licenseKey = licenseKey;
        }
    }

    private static String trimToNull(String v) {
        if (v == null) return null;
        String t = v.trim();
        return t.length() == 0 ? null : t;
    }

    // This package's bare namespace ('NSIQ_SignForce'), or null when running
    // unmanaged in the packaging org. Used to filter PermissionSet.NamespacePrefix
    // so lookups target our packaged perm sets, not a subscriber's same-named one.
    // Avoids hardcoding the namespace string.
    private static Boolean nsLoaded = false;
    private static String cachedNs;
    @TestVisible
    private static String packageNs() {
        if (nsLoaded) return cachedNs;
        nsLoaded = true;
        try {
            cachedNs = [
                SELECT NamespacePrefix FROM ApexClass
                WHERE Name = 'SignForceAdminConfigController' WITH USER_MODE LIMIT 1
            ].NamespacePrefix;
        } catch (Exception e) {
            cachedNs = null;
        }
        return cachedNs;
    }

    /**
     * True when the running user has "Customize Application" (i.e. is an admin who
     * may use the setup wizard). Non-throwing so the LWC can gate its own UI and
     * show an access-denied screen instead of a broken wizard full of errors.
     */
    @AuraEnabled(cacheable=true)
    public static Boolean hasAdminAccess() {
        return isCurrentUserAdmin();
    }

    private static Boolean isCurrentUserAdmin() {
        // The try/catch is what keeps hasAdminAccess() to its contract. In USER_MODE
        // this query throws for a user who cannot read PermissionSetAssignment —
        // which is exactly the non-admin this method exists to identify. Without
        // the catch the LWC would get an exception instead of a false, and the
        // access-denied screen would be replaced by a broken wizard.
        //
        // Failing closed is the right default here: if we cannot prove the user is
        // an administrator, they are not treated as one.
        try {
            return [
                SELECT COUNT() FROM PermissionSetAssignment
                WHERE AssigneeId = :UserInfo.getUserId()
                  AND PermissionSet.PermissionsCustomizeApplication = true
                WITH USER_MODE
            ] > 0;
        } catch (Exception e) {
            return false;
        }
    }

    private static void requireAdmin() {
        if (!isCurrentUserAdmin()) {
            throw new AuraHandledException(
                'Administrator permission (Customize Application) is required for this action.'
            );
        }
    }

    public class IntegrationConfig {
        @AuraEnabled public String provider;
        @AuraEnabled public Boolean enabled;
        @AuraEnabled public String target;
        @AuraEnabled public String targetName;
        @AuraEnabled public String clientId;
        @AuraEnabled public String clientSecret;

        public IntegrationConfig() {}

        public IntegrationConfig(String provider, Boolean enabled, String target) {
            this.provider = provider;
            this.enabled = enabled;
            this.target = target;
        }

        public IntegrationConfig(String provider, Boolean enabled, String target, String clientId, String clientSecret) {
            this.provider = provider;
            this.enabled = enabled;
            this.target = target;
            this.clientId = clientId;
            this.clientSecret = clientSecret;
        }
    }

    public class IntegrationActionResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String message;
        @AuraEnabled public String url;

        public IntegrationActionResult() {}
        public IntegrationActionResult(Boolean success, String message, String url) {
            this.success = success;
            this.message = message;
            this.url = url;
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<IntegrationConfig> getIntegrationConfig() {
        requireAdmin();
        // getOrgDefaults() is null on a fresh org with no config record yet — use an
        // empty instance so the integration panel loads instead of NPE-ing.
        SignForce_Admin_Config__c cs = SignForce_Admin_Config__c.getOrgDefaults();
        if (cs == null) cs = new SignForce_Admin_Config__c();
        IntegrationConfig gd = new IntegrationConfig('GoogleDrive', cs.Integration_GoogleDrive_Enabled__c, cs.Integration_GoogleDrive_Target__c, SignForceConfigService.getGoogleClientId(), SignForceConfigService.getGoogleClientSecret());
        gd.targetName = cs.Integration_GoogleDrive_Target_Name__c;
        IntegrationConfig od = new IntegrationConfig('OneDrive', cs.Integration_OneDrive_Enabled__c, cs.Integration_OneDrive_Target__c, SignForceConfigService.getMicrosoftClientId(), SignForceConfigService.getMicrosoftClientSecret());
        od.targetName = cs.Integration_OneDrive_Target_Name__c;
        return new List<IntegrationConfig>{
            new IntegrationConfig('AwsS3', cs.Integration_AwsS3_Enabled__c, cs.Integration_AwsS3_Target__c),
            new IntegrationConfig('Box', cs.Integration_Box_Enabled__c, cs.Integration_Box_Target__c),
            gd,
            od,
            new IntegrationConfig('SharePoint', cs.Integration_SharePoint_Enabled__c, cs.Integration_SharePoint_Target__c)
        };
    }

    @AuraEnabled
    public static void saveIntegrationConfig(String jsonStr) {
        requireAdmin();
        List<IntegrationConfig> configs = (List<IntegrationConfig>) JSON.deserialize(jsonStr, List<IntegrationConfig>.class);
        // Query-or-create so a first-time save on a fresh org doesn't NPE / fail upsert.
        List<SignForce_Admin_Config__c> existing = [
            SELECT Id FROM SignForce_Admin_Config__c
            WHERE SetupOwnerId = :UserInfo.getOrganizationId() WITH USER_MODE LIMIT 1
        ];
        SignForce_Admin_Config__c cs = existing.isEmpty()
            ? new SignForce_Admin_Config__c(SetupOwnerId = UserInfo.getOrganizationId())
            : existing[0];
        for (IntegrationConfig cfg : configs) {
            if (cfg.provider == 'AwsS3') {
                cs.Integration_AwsS3_Enabled__c = cfg.enabled;
                cs.Integration_AwsS3_Target__c = cfg.target;
            } else if (cfg.provider == 'Box') {
                cs.Integration_Box_Enabled__c = cfg.enabled;
                cs.Integration_Box_Target__c = cfg.target;
            } else if (cfg.provider == 'GoogleDrive') {
                cs.Integration_GoogleDrive_Enabled__c = cfg.enabled;
                cs.Integration_GoogleDrive_Target__c = cfg.target;
                cs.Integration_GoogleDrive_Target_Name__c = cfg.targetName;
                cs.Google_Client_ID__c = cfg.clientId;
                cs.Google_Client_Secret__c = cfg.clientSecret;
            } else if (cfg.provider == 'OneDrive') {
                cs.Integration_OneDrive_Enabled__c = cfg.enabled;
                cs.Integration_OneDrive_Target__c = cfg.target;
                cs.Integration_OneDrive_Target_Name__c = cfg.targetName;
                cs.Microsoft_Client_ID__c = cfg.clientId;
                cs.Microsoft_Client_Secret__c = cfg.clientSecret;
            } else if (cfg.provider == 'SharePoint') {
                cs.Integration_SharePoint_Enabled__c = cfg.enabled;
                cs.Integration_SharePoint_Target__c = cfg.target;
            }
        }
        Database.upsert(cs, SignForce_Admin_Config__c.Id, true, AccessLevel.USER_MODE);
    }

    /**
     * The Google API key used by the folder Picker.
     *
     * It lives on the custom setting and, unlike the client ID/secret, is NOT
     * shipped in the packaged config metadata - every org needs its own. Without
     * a screen to enter it, getGooglePickerConfig() can only tell the admin to
     * "add one" with nowhere to add it, so these two methods back that field.
     *
     * This value is not a secret: the Picker runs in the browser and Google
     * expects the key to be visible there, restricted by HTTP referrer instead.
     */
    @AuraEnabled
    public static String getGoogleApiKey() {
        requireAdmin();
        SignForce_Admin_Config__c cs = SignForce_Admin_Config__c.getOrgDefaults();
        return cs == null ? null : cs.Google_API_Key__c;
    }

    @AuraEnabled
    public static void saveGoogleApiKey(String apiKey) {
        requireAdmin();
        List<SignForce_Admin_Config__c> existing = [
            SELECT Id FROM SignForce_Admin_Config__c
            WHERE SetupOwnerId = :UserInfo.getOrganizationId() WITH USER_MODE LIMIT 1
        ];
        SignForce_Admin_Config__c cs = existing.isEmpty()
            ? new SignForce_Admin_Config__c(SetupOwnerId = UserInfo.getOrganizationId())
            : existing[0];
        cs.Google_API_Key__c = trimToNull(apiKey);
        Database.upsert(cs, SignForce_Admin_Config__c.Id, true, AccessLevel.USER_MODE);
    }

    /**
     * Domains the Google folder Picker loads from. Without a CSP Trusted Site for
     * each one the browser silently refuses the frame and the Picker renders as an
     * empty box - which reads to an admin as "the folder list is empty" rather than
     * as a configuration problem.
     *
     * Apex can READ CspTrustedSite but cannot insert it, so this only reports what
     * is missing; an administrator adds them in Setup.
     */
    private static final List<String> PICKER_DOMAINS = new List<String>{
        'https://apis.google.com',            // the Picker loader
        'https://docs.google.com',            // the Picker UI frame
        'https://drive.google.com',           // Drive content
        'https://accounts.google.com',        // Google sign-in
        'https://*.gstatic.com',              // Picker static assets
        'https://*.googleusercontent.com'     // thumbnails and avatars
    };

    public class TrustedSiteStatus {
        @AuraEnabled public Boolean allPresent = true;
        @AuraEnabled public List<String> missing = new List<String>();
    }

    @AuraEnabled
    public static TrustedSiteStatus getPickerTrustedSites() {
        requireAdmin();
        TrustedSiteStatus st = new TrustedSiteStatus();

        Set<String> active = new Set<String>();
        try {
            for (CspTrustedSite site : [
                SELECT EndpointUrl, IsActive, Context FROM CspTrustedSite
            ]) {
                // Context 'All' covers Lightning and Visualforce; the Picker is hosted
                // on a Visualforce page but opened from Lightning, so it needs both.
                if (site.IsActive == true && String.isNotBlank(site.EndpointUrl)) {
                    active.add(site.EndpointUrl.trim().toLowerCase());
                }
            }
        } catch (Exception e) {
            // If the object is unreadable we cannot tell - say nothing rather than
            // cry wolf on a working org.
            return st;
        }

        for (String d : PICKER_DOMAINS) {
            if (!active.contains(d.toLowerCase())) st.missing.add(d);
        }
        st.allPresent = st.missing.isEmpty();
        return st;
    }

    @AuraEnabled
    public static IntegrationActionResult testIntegration(String provider) {
        requireAdmin();
        IntegrationService.Result res = IntegrationService.testConnection(provider);
        return new IntegrationActionResult(res.success, res.message, null);
    }

    @AuraEnabled
    public static IntegrationActionResult getIntegrationConnectUrl(String provider) {
        requireAdmin();
        IntegrationService.Result res = IntegrationService.getConnectUrl(provider);
        return new IntegrationActionResult(res.success, res.message, res.url);
    }

    public class GoogleFolder {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        public GoogleFolder(String id, String name) {
            this.id = id;
            this.name = name;
        }
    }

    public class FolderResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String message;
        @AuraEnabled public List<GoogleFolder> folders;
        @AuraEnabled public String folderId;
        @AuraEnabled public String folderName;
    }

    /** What the browser needs to open the Google Picker. */
    public class PickerConfig {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String message;
        @AuraEnabled public String accessToken;
        @AuraEnabled public String developerKey;
        // Built here rather than in JavaScript: once packaged the page is
        // /apex/esignforce__GooglePickerHost, and Page.X.getUrl() is the only
        // thing that gets the namespace right in both the packaging org and a
        // subscriber org.
        @AuraEnabled public String pageUrl;
    }

    /**
     * Supplies the Google Picker with a Drive access token and the org's Google
     * API key.
     *
     * This replaces listGoogleFolders for new connections. Under the drive.file
     * scope the app cannot enumerate anybody's Drive, which is the point: the
     * admin hands it one folder through the Picker and the app's reach stops
     * there.
     *
     * requireAdmin() is load-bearing here, not boilerplate. This method returns a
     * live Google access token to the browser, so it must never be reachable by a
     * user who is not already trusted with the org's integration settings.
     */
    @AuraEnabled
    public static PickerConfig getGooglePickerConfig() {
        requireAdmin();
        PickerConfig res = new PickerConfig();
        try {
            SignForce_Admin_Config__c cfg = SignForce_Admin_Config__c.getOrgDefaults();

            // The API key is OPTIONAL. The Picker ran on the OAuth token alone before
            // this field existed, and blocking on it turned an upgrade into an outage
            // for every org that had been working fine. An org may still supply its
            // own key - to bill Picker calls to its own Google Cloud project - and
            // when it does we pass it through.
            String apiKey = cfg != null ? cfg.Google_API_Key__c : null;

            HttpResponse httpRes = IntegrationService.callBackend(new Map<String, Object>{
                'action' => 'getPickerConfig',
                'orgId' => UserInfo.getOrganizationId(),
                'clientId' => cfg.Google_Client_ID__c,
                'clientSecret' => cfg.Google_Client_Secret__c
            });

            Integer sc = httpRes.getStatusCode();
            if (sc >= 200 && sc < 300) {
                Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(httpRes.getBody());
                if (body.get('success') == true) {
                    res.success = true;
                    res.accessToken = String.valueOf(body.get('accessToken'));
                    res.developerKey = apiKey;
                    res.pageUrl = Page.GooglePickerHost.getUrl();
                } else {
                    res.success = false;
                    res.message = String.valueOf(body.get('message'));
                }
            } else {
                res.success = false;
                res.message = 'HTTP ' + sc + ': ' + httpRes.getBody();
            }
        } catch (Exception e) {
            res.success = false;
            res.message = e.getMessage();
        }
        return res;
    }

    /**
     * Kept for orgs that connected before the scope change. Their stored token is
     * still the broad drive scope and can still list, so removing this would break
     * them mid-upgrade. New connections are drive.file and use the Picker instead.
     */
    @AuraEnabled
    public static FolderResult listGoogleFolders() {
        requireAdmin();
        FolderResult res = new FolderResult();
        try {
            SignForce_Admin_Config__c cfg = SignForce_Admin_Config__c.getOrgDefaults();
            HttpResponse httpRes = IntegrationService.callBackend(new Map<String, Object>{
                'action' => 'listGoogleFolders',
                'orgId' => UserInfo.getOrganizationId(),
                'clientId' => cfg.Google_Client_ID__c,
                'clientSecret' => cfg.Google_Client_Secret__c
            });

            Integer sc = httpRes.getStatusCode();
            if (sc >= 200 && sc < 300) {
                Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(httpRes.getBody());
                if (body.get('success') == true) {
                    res.success = true;
                    res.folders = new List<GoogleFolder>();
                    List<Object> foldersList = (List<Object>) body.get('folders');
                    if (foldersList != null) {
                        for (Object fObj : foldersList) {
                            Map<String, Object> fMap = (Map<String, Object>) fObj;
                            res.folders.add(new GoogleFolder(
                                String.valueOf(fMap.get('id')),
                                String.valueOf(fMap.get('name'))
                            ));
                        }
                    }
                } else {
                    res.success = false;
                    res.message = String.valueOf(body.get('message'));
                }
            } else {
                res.success = false;
                res.message = 'HTTP ' + sc + ': ' + httpRes.getBody();
            }
        } catch (Exception e) {
            res.success = false;
            res.message = e.getMessage();
        }
        return res;
    }

    /**
     * OneDrive folder listing. Deliberately a separate method with its own backend
     * action rather than a generic one shared with Google — the Google path must
     * keep talking to the backend exactly as it always has.
     */
    @AuraEnabled
    public static FolderResult listOneDriveFolders() {
        requireAdmin();
        FolderResult res = new FolderResult();
        try {
            // The Microsoft credential getters fall back to SignForce_Config__mdt,
            // which SignForceConfigService.load() reads with an unenforced dynamic
            // query. This read check covers that path; a no-op for the admins
            // requireAdmin() lets through, who can always read custom metadata.
            SignForceFLS.requireAccessible(SignForce_Config__mdt.SObjectType);
            HttpResponse httpRes = IntegrationService.callBackend(new Map<String, Object>{
                'action' => 'listOneDriveFolders',
                'provider' => IntegrationService.ONE_DRIVE,
                'orgId' => UserInfo.getOrganizationId(),
                'clientId' => SignForceConfigService.getMicrosoftClientId(),
                'clientSecret' => SignForceConfigService.getMicrosoftClientSecret()
            });

            Integer sc = httpRes.getStatusCode();
            if (sc >= 200 && sc < 300) {
                Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(httpRes.getBody());
                if (body.get('success') == true) {
                    res.success = true;
                    res.folders = new List<GoogleFolder>();
                    List<Object> foldersList = (List<Object>) body.get('folders');
                    if (foldersList != null) {
                        for (Object fObj : foldersList) {
                            Map<String, Object> fMap = (Map<String, Object>) fObj;
                            res.folders.add(new GoogleFolder(
                                String.valueOf(fMap.get('id')),
                                String.valueOf(fMap.get('name'))
                            ));
                        }
                    }
                } else {
                    res.success = false;
                    res.message = String.valueOf(body.get('message'));
                }
            } else {
                res.success = false;
                res.message = 'HTTP ' + sc + ': ' + httpRes.getBody();
            }
        } catch (Exception e) {
            res.success = false;
            res.message = e.getMessage();
        }
        return res;
    }

    @AuraEnabled
    public static FolderResult createOneDriveFolder(String folderName, String parentId) {
        requireAdmin();
        FolderResult res = new FolderResult();
        try {
            // Same CMT-fallback read check as listOneDriveFolders.
            SignForceFLS.requireAccessible(SignForce_Config__mdt.SObjectType);
            HttpResponse httpRes = IntegrationService.callBackend(new Map<String, Object>{
                'action' => 'createOneDriveFolder',
                'provider' => IntegrationService.ONE_DRIVE,
                'folderName' => folderName,
                'parentId' => parentId,
                'orgId' => UserInfo.getOrganizationId(),
                'clientId' => SignForceConfigService.getMicrosoftClientId(),
                'clientSecret' => SignForceConfigService.getMicrosoftClientSecret()
            });

            Integer sc = httpRes.getStatusCode();
            if (sc >= 200 && sc < 300) {
                Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(httpRes.getBody());
                if (body.get('success') == true) {
                    res.success = true;
                    res.folderId = String.valueOf(body.get('folderId'));
                    res.folderName = String.valueOf(body.get('folderName'));
                } else {
                    res.success = false;
                    res.message = String.valueOf(body.get('message'));
                }
            } else {
                res.success = false;
                res.message = 'HTTP ' + sc + ': ' + httpRes.getBody();
            }
        } catch (Exception e) {
            res.success = false;
            res.message = e.getMessage();
        }
        return res;
    }

    @AuraEnabled
    public static FolderResult createGoogleFolder(String folderName, String parentId) {
        requireAdmin();
        FolderResult res = new FolderResult();
        try {
            SignForce_Admin_Config__c cfg = SignForce_Admin_Config__c.getOrgDefaults();
            HttpResponse httpRes = IntegrationService.callBackend(new Map<String, Object>{
                'action' => 'createGoogleFolder',
                'folderName' => folderName,
                'parentId' => parentId,
                'orgId' => UserInfo.getOrganizationId(),
                'clientId' => cfg.Google_Client_ID__c,
                'clientSecret' => cfg.Google_Client_Secret__c
            });

            Integer sc = httpRes.getStatusCode();
            if (sc >= 200 && sc < 300) {
                Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(httpRes.getBody());
                if (body.get('success') == true) {
                    res.success = true;
                    res.folderId = String.valueOf(body.get('folderId'));
                    res.folderName = String.valueOf(body.get('folderName'));
                } else {
                    res.success = false;
                    res.message = String.valueOf(body.get('message'));
                }
            } else {
                res.success = false;
                res.message = 'HTTP ' + sc + ': ' + httpRes.getBody();
            }
        } catch (Exception e) {
            res.success = false;
            res.message = e.getMessage();
        }
        return res;
    }

    @AuraEnabled
    public static IntegrationActionResult disconnectIntegration(String provider) {
        requireAdmin();
        try {
            HttpResponse httpRes = IntegrationService.callBackend(new Map<String, Object>{
                'action' => 'disconnectCloud',
                'provider' => provider,
                'orgId' => UserInfo.getOrganizationId()
            });
            Integer sc = httpRes.getStatusCode();
            if (sc >= 200 && sc < 300) {
                Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(httpRes.getBody());
                Boolean ok = body != null && body.get('success') == true;
                String msg = body != null && body.get('message') != null ? String.valueOf(body.get('message')) : 'Disconnected';
                return new IntegrationActionResult(ok, msg, null);
            }
            return new IntegrationActionResult(false, 'HTTP ' + sc + ': ' + httpRes.getBody(), null);
        } catch (Exception e) {
            return new IntegrationActionResult(false, e.getMessage(), null);
        }
    }
}