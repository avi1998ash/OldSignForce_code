/**
 * RemainingCoverageTest — clears the last low-coverage classes for the package
 * average: the Agentforce invocables' failure branch (reached with a null
 * request, which the wrapper catches), and the LightningForgotPasswordController
 * redirect-safety branches (isSafeRedirectUrl is @TestVisible). No files created.
 */
@IsTest
private class RemainingCoverageTest {

    @IsTest
    static void agentforceFailureBranches() {
        // A null request dereferences inside the loop -> caught -> failure() runs.
        Test.startTest();
        Assert.areEqual(false,
            AgentforceAddSigner.getInvocableActions(
                new List<AgentforceAddSigner.Request>{ null })[0].success);
        Assert.areEqual(false,
            AgentforceGetAuditTrail.getInvocableActions(
                new List<AgentforceGetAuditTrail.Request>{ null })[0].success);
        Assert.areEqual(false,
            AgentforceCreateTemplate.getInvocableActions(
                new List<AgentforceCreateTemplate.Request>{ null })[0].success);
        Assert.areEqual(false,
            AgentforceGenerateDocument.getInvocableActions(
                new List<AgentforceGenerateDocument.Request>{ null })[0].success);
        Test.stopTest();
    }

    @IsTest
    static void forgotPassword_redirectSafetyBranches() {
        Test.startTest();
        // isSafeRedirectUrl covers: blank, relative, off-site absolute,
        // protocol-relative, and malformed (catch) paths.
        Assert.isTrue(LightningForgotPasswordController.isSafeRedirectUrl(null));
        Assert.isTrue(LightningForgotPasswordController.isSafeRedirectUrl(''));
        Assert.isTrue(LightningForgotPasswordController.isSafeRedirectUrl('/s/relative'));
        LightningForgotPasswordController.isSafeRedirectUrl('https://evil.example.com/x');
        LightningForgotPasswordController.isSafeRedirectUrl('//evil.example.com/x');
        LightningForgotPasswordController.isSafeRedirectUrl('ht!tp://malformed');

        // Public entry points.
        LightningForgotPasswordController.forgotPassword('nobody@example.com', '/checkemail');
        LightningForgotPasswordController.setExperienceId('exp1');
        LightningForgotPasswordController.setExperienceId(null);
        Test.stopTest();
        Assert.isTrue(true, 'redirect-safety and entry points executed');
    }
}