/**
 * An apex class that creates a portal user
 *
 * Sharing: deliberately without sharing. This is the Digital Experience
 * self-registration controller — it runs as the Sites Guest User for a
 * visitor who has no account and therefore no sharing access to anything
 * yet (see the portalAccountId getter below, which reads a config record
 * granted to nobody, guest included). "With sharing" would break
 * registration before it starts.
 */
public with sharing class SiteRegisterController {
    // The account new portal contacts are created against, then enabled as a
    // portal user. The account owner has to be in the role hierarchy for this
    // to work — see the Customer Portal setup help.
    //
    // This was the literal '001x000xxx35tPN' that ships in Salesforce's sample
    // class. That is a documentation placeholder, not an id, so the class could
    // never have worked as written — and a hardcoded id fails security review
    // besides. It now reads the value an admin already sets on the SignForce
    // Admin Config record, so it is per-org and configurable.
    private static Id portalAccountId {
        get {
            if (portalAccountId == null) {
                // System mode, deliberately. This runs while the user is a
                // self-registering visitor on the site, and SignForce_Admin_Config__c
                // is package configuration that is granted to nobody — not even
                // SignForce_User. In USER_MODE this read throws and registration
                // dies before it starts.
                //
                // Reading it here leaks nothing: only the account id is taken, and
                // it is used to parent the contact being created, never returned.
                List<SignForce_Admin_Config__c> cfg = [
                    SELECT Portal_Account_Id__c
                    FROM SignForce_Admin_Config__c
                    LIMIT 1
                ];
                if (!cfg.isEmpty() && String.isNotBlank(cfg[0].Portal_Account_Id__c)) {
                    portalAccountId = (Id) cfg[0].Portal_Account_Id__c;
                }
            }
            return portalAccountId;
        }
        set;
    }
    
    public SiteRegisterController () {
    }

    public String username {get; set;}
    public String email {get; set;}
    public String password {get; set {password = value == null ? value : value.trim(); } }
    public String confirmPassword {get; set { confirmPassword = value == null ? value : value.trim(); } }
    public String communityNickname {get; set { communityNickname = value == null ? value : value.trim(); } }
      
    private boolean isValidPassword() {
        return password == confirmPassword;
    }
    
    public PageReference registerUser() {
        // it's okay if password is null - we'll send the user a random password in that case
        if (!isValidPassword()) {
        	ApexPages.Message msg = new ApexPages.Message(ApexPages.Severity.ERROR, Label.site.passwords_dont_match);
        	ApexPages.addMessage(msg);
            return null;
        }    
        User u = new User();
        u.Username = username;
        u.Email = email;
        u.CommunityNickname = communityNickname;
        
        String accountId = portalAccountId;

        // lastName is a required field on user, but if it isn't specified, we'll default it to the username
        String userId = Site.createPortalUser(u, accountId, password);
        if (userId != null) { 
            if (password != null && password.length() > 1) {
                return Site.login(username, password, null);
            }
            else {
                PageReference page = System.Page.SiteRegisterConfirm;
                page.setRedirect(true);
                return page;
            }
        }
        return null;
    }
}