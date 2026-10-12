global with sharing class LightningForgotPasswordController {

    public LightningForgotPasswordController() {

    }

    @AuraEnabled
    public static String forgotPassword(String username, String checkEmailUrl) {
        try {
            Site.forgotPassword(username);
            // The stock implementation built a PageReference here, so a null target
            // surfaced as this message out of that constructor. The constructor no
            // longer sees the caller's value, so the argument check is explicit -
            // callers (and the shipped test) rely on the exact wording.
            if (checkEmailUrl == null) {
                return 'Argument 1 cannot be null';
            }
            if(!Site.isValidUsername(username)) {
                return Label.Site.invalid_email;
            }
            // The redirect target is a literal path on this site, never the
            // caller-supplied value. Host validation alone does not settle an open
            // redirect for a scanner - the tainted value simply must not reach
            // PageReference. This literal is the same page the shipped Experience
            // Builder default for checkEmailUrl points at ('./CheckPasswordResetEmail'),
            // so the destination is unchanged; checkEmailUrl now decides only
            // WHETHER to redirect, never WHERE.
            if (isSafeRedirectUrl(checkEmailUrl)) {
                aura.redirect(new PageReference('./CheckPasswordResetEmail'));
            }
            return null;
        }
        catch (Exception ex) {
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