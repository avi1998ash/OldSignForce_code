global with sharing class LightningSelfRegisterController {

    public LightningSelfRegisterController() {

    }

    @TestVisible 
    private static boolean isValidPassword(String password, String confirmPassword) {
        return password == confirmPassword;
    }
    
    @TestVisible 
    private static boolean siteAsContainerEnabled(String communityUrl) {
        Auth.AuthConfiguration authConfig = new Auth.AuthConfiguration(communityUrl,'');
        return authConfig.isCommunityUsingSiteAsContainer();
    }
    
    @TestVisible 
    private static void validatePassword(User u, String password, String confirmPassword) {
        if(!Test.isRunningTest()) {
        Site.validatePassword(u, password, confirmPassword);
        }
        return;
    }
    
    @AuraEnabled
    public static String selfRegister(String firstname ,String lastname, String email, String password, String confirmPassword, String accountId, String regConfirmUrl, String extraFields, String startUrl, Boolean includePassword) {
        Savepoint sp = null;
        try {
            sp = Database.setSavepoint();
            
            if (lastname == null || String.isEmpty(lastname)) {
                return Label.Site.lastname_is_required;
            }
            
            if (email == null || String.isEmpty(email)) {
                return Label.Site.email_is_required;
            }
            
            User u = new User();
            u.Username = email;
            u.put('Email',email);
            
            u.FirstName = firstname;
            u.LastName = lastname;
            
            String networkId = Network.getNetworkId();

            // If using site to host the community the user should not hit s1 after logging in from mobile.
            if(networkId != null && siteAsContainerEnabled(Network.getLoginUrl(networkId))) {
                u.put('UserPreferencesHideS1BrowserUI',true);
            }
            
            String nickname = ((firstname != null && firstname.length() > 0) ? firstname.substring(0,1) : '' ) + lastname.substring(0,1);
            nickname += String.valueOf(Crypto.getRandomInteger()).substring(1,7);
            u.put('CommunityNickname', nickname);
                     
            if (extraFields != null) {
                List<Object> extraFieldsList = (List<Object>) JSON.deserializeUntyped(extraFields);        
                for (Object thisFieldObject : extraFieldsList) {
                    Map<String,Object> thisField = (Map<String,Object>) thisFieldObject;
                    Schema.SObjectField sof = Schema.SObjectType.User.fields.getMap().get((String) thisField.get('fieldPath'));
                    u.put(sof, thisField.get('value'));
                }
            }
                        
            if (includePassword) {    
                if (!isValidPassword(password, confirmPassword)) {
                    return Label.site.passwords_dont_match;
                }
             validatePassword(u, password, confirmPassword);
            }
            else {
                password = null;
            }
            
            // lastName is a required field on user, but if it isn't specified, we'll default it to the username
            String userId = Site.createPortalUser(u, accountId, password);
            // create a fake userId for test.
            if (Test.isRunningTest()) {
                userId = 'fakeUserId';           
            }
            if (userId != null) {
                if (password != null && password.length() > 1) {
                    // startUrl is caller-supplied; an unvalidated value would let Site.login
                    // hand back a redirect to an attacker's host. Fall back to Site.login's
                    // own default landing page rather than following an off-site target.
                    String safeStartUrl = isSafeRedirectUrl(startUrl) ? startUrl : null;
                    ApexPages.PageReference lgn = Site.login(email, password, safeStartUrl);
                    if(!Test.isRunningTest()) {
                     aura.redirect(lgn);
                    }
                }
                else {
                    // Same open-redirect concern for regConfirmUrl, and the same
                    // resolution: the caller's value no longer reaches PageReference at
                    // all. The target is the literal path this component's shipped
                    // Experience Builder default already points at, so the destination
                    // is unchanged while an off-site URL can no longer be built from
                    // input. regConfirmUrl still gates whether we redirect.
                    if (isSafeRedirectUrl(regConfirmUrl)) {
                        ApexPages.PageReference confirmRef = new PageReference('./CheckPasswordResetEmail');
                        if(!Test.isRunningTest()) {
                        aura.redirect(confirmRef);
                       }
                    }
                }
            }
            return null;
        }
        catch (Exception ex) {
            Database.rollback(sp);
            return ex.getMessage();
        }
    }

    // Relative paths ("/s/...", "./Foo") always resolve on this same site, so only
    // absolute/protocol-relative URLs need a host check against the site's own domain.
    @TestVisible
    private static Boolean isSafeRedirectUrl(String targetUrl) {
        if (String.isBlank(targetUrl)) {
            return true;
        }
        String trimmedUrl = targetUrl.trim();
        Boolean looksAbsolute = trimmedUrl.startsWith('//') || Pattern.matches('(?i)^[a-z][a-z0-9+.\\-]*://.*', trimmedUrl);
        if (!looksAbsolute) {
            return true;
        }
        try {
            String normalizedUrl = trimmedUrl.startsWith('//') ? 'https:' + trimmedUrl : trimmedUrl;
            String targetHost = new URL(normalizedUrl).getHost();
            String trustedHost = new URL(Site.getBaseUrl()).getHost();
            return targetHost != null && trustedHost != null && targetHost.equalsIgnoreCase(trustedHost);
        } catch (Exception e) {
            return false;
        }
    }
    
    @AuraEnabled
    public static List<Map<String,Object>> getExtraFields(String extraFieldsFieldSet) { 
        List<Map<String,Object>> extraFields = new List<Map<String,Object>>();
        Schema.FieldSet fieldSet = Schema.SObjectType.User.fieldSets.getMap().get(extraFieldsFieldSet);
        if(!Test.isRunningTest()) {
        if (fieldSet != null) {
            for (Schema.FieldSetMember f : fieldSet.getFields()) {
                Map<String, Object> fieldDetail = new Map<String, Object>();
                fieldDetail.put('dbRequired', f.getDBRequired());
                fieldDetail.put('fieldPath', f.getFieldPath());
                fieldDetail.put('label', f.getLabel());
                fieldDetail.put('required', f.getRequired());
                fieldDetail.put('type', f.getType());
                fieldDetail.put('value', '');   // client will populate
                extraFields.add(fieldDetail);
            }}}
        return extraFields;
    }
    
    @AuraEnabled
    global static String setExperienceId(String expId) {
        // Return null if there is no error, else it will return the error message 
        try {
            if (expId != null) {
                Site.setExperienceId(expId);   
            }
            return null; 
        } catch (Exception ex) {
            return ex.getMessage();            
        }        
    }  
}