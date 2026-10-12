/**
 * Lightweight access check shared by the SignForce internal LWCs. The gate
 * component (c-signforce-access-gate) calls this to decide whether to render its
 * content or a "contact your admin" message.
 *
 * Access is defined as read access to Agreement__c — the object the SignForce_User
 * permission set grants. A user who can't see agreements has no use for the
 * authoring/management tools, so they see the gate instead.
 *
 * Guest/community components (the signing experience) are deliberately NOT gated
 * this way — signers are guest users without object access.
 */
public with sharing class SignForceAccess {
    @AuraEnabled(cacheable=true)
    public static Boolean hasAgreementAccess() {
        return Schema.SObjectType.Agreement__c.isAccessible();
    }

    /**
     * Whether the Agentforce-powered UI should be shown.
     *
     * ── TEMPORARILY FORCED OFF ──────────────────────────────────────────────
     * Agentforce is being kept out of sight for now, so this returns false
     * unconditionally. Every Agentforce surface in the product reads this one
     * method, so nothing else had to be touched:
     *
     *   - signforceChatbotFab      the floating assistant button, placed on the
     *                              SignForce home page and the Agreement record
     *                              page (both flexipages still host it; the
     *                              component simply renders nothing)
     *   - signforceVoiceAssistant  the voice panel
     *   - SignForceAdminConfigController.getPermissionSetStatus
     *                              drops the Agentforce permission set from the
     *                              admin wizard's steps 3 and 6
     *
     * The Apex actions, genAiFunctions and the SignForce_Assistant bot are left
     * in place and untouched — they are not user-visible on their own.
     *
     * TO BRING IT BACK: delete the `return false` and uncomment the original
     * check below. Nothing else needs changing.
     *
     * ── Original behaviour ──────────────────────────────────────────────────
     * True when Agentforce (Einstein generative AI) is provisioned in this org.
     *
     * Signal: the AIApplication sObject exists. It's the Einstein/Agentforce
     * platform object and simply isn't present in orgs without the feature, so a
     * global-describe lookup is a cheap, permission-independent check. The agent
     * itself (BotDefinition) is a Tooling-only object and can't be queried from
     * Apex SOQL, so we detect the platform rather than the specific agent.
     */
    @AuraEnabled(cacheable=true)
    public static Boolean isAgentforceAvailable() {
        return false;
        // return Schema.getGlobalDescribe().containsKey('AIApplication');
    }
}